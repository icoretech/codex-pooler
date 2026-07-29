defmodule CodexPooler.Upstreams.SavedResetRedemptionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
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
      redemption = persisted.metadata["saved_reset_redemption"]

      for key <- scheduled_decision_metadata_keys() do
        refute Map.has_key?(redemption, key)
      end

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

  describe "scheduled expiry rescue" do
    @describetag :scheduled_expiry_rescue

    test "encodes exactly five bounded scheduled decision fields" do
      utc_seconds = ~U[2026-07-29 12:00:00Z]
      utc_microseconds = ~U[2026-07-29 12:00:00.123456Z]
      {:ok, non_utc, _offset} = DateTime.from_iso8601("2026-07-29T13:00:00+01:00")

      for trigger_detail <- ["immediate_expiry", "exhausted", "threshold", "last_call"],
          used_percent <- [
            Decimal.new("0"),
            Decimal.new("0.001"),
            Decimal.new("99.999"),
            Decimal.new("100"),
            Decimal.new("1.2300"),
            Decimal.new("123E-2")
          ] do
        assert {:ok, evidence} =
                 SavedResetRedemption.encode_scheduled_decision_evidence(%{
                   trigger_detail: trigger_detail,
                   used_percent_at_decision: used_percent,
                   credit_expires_at_at_decision: utc_seconds,
                   natural_reset_at_decision: non_utc,
                   decided_at: utc_microseconds
                 })

        assert Map.keys(evidence) |> Enum.sort() == scheduled_decision_atom_keys()
        assert evidence.trigger_detail == trigger_detail

        assert evidence.used_percent_at_decision ==
                 used_percent |> Decimal.normalize() |> Decimal.to_string(:normal)

        assert evidence.credit_expires_at_at_decision == "2026-07-29T12:00:00Z"
        assert evidence.natural_reset_at_decision == "2026-07-29T12:00:00Z"
        assert evidence.decided_at == "2026-07-29T12:00:00.123456Z"

        assert byte_size(evidence.trigger_detail) in 9..16
        assert byte_size(evidence.used_percent_at_decision) in 1..6

        for timestamp_key <- [
              :credit_expires_at_at_decision,
              :natural_reset_at_decision,
              :decided_at
            ] do
          assert byte_size(Map.fetch!(evidence, timestamp_key)) in 20..27
          assert String.ends_with?(Map.fetch!(evidence, timestamp_key), "Z")
        end
      end
    end

    test "rejects malformed scheduled decision contexts without coercion or rounding" do
      valid = %{
        trigger_detail: "immediate_expiry",
        used_percent_at_decision: Decimal.new("25"),
        credit_expires_at_at_decision: ~U[2026-07-29 13:00:00Z],
        natural_reset_at_decision: ~U[2026-07-29 14:00:00Z],
        decided_at: ~U[2026-07-29 12:00:00Z]
      }

      invalid_contexts = [
        nil,
        %{},
        Map.put(valid, :extra, "not-persisted"),
        Map.put(valid, :trigger_detail, " immediate_expiry"),
        Map.put(valid, :trigger_detail, "other"),
        Map.put(valid, :used_percent_at_decision, 25),
        Map.put(valid, :used_percent_at_decision, Decimal.new("-0.001")),
        Map.put(valid, :used_percent_at_decision, Decimal.new("100.001")),
        Map.put(valid, :used_percent_at_decision, Decimal.new("0.0001")),
        Map.put(valid, :used_percent_at_decision, Decimal.new("NaN")),
        Map.put(valid, :used_percent_at_decision, Decimal.new("Infinity")),
        Map.put(valid, :credit_expires_at_at_decision, "2026-07-29T13:00:00Z"),
        Map.put(valid, :natural_reset_at_decision, nil),
        Map.put(valid, :decided_at, ~N[2026-07-29 12:00:00])
      ]

      for context <- invalid_contexts do
        assert {:error, :invalid_decision_evidence} =
                 SavedResetRedemption.encode_scheduled_decision_evidence(context)
      end
    end

    test "pure burn decision applies exhausted, threshold, and last-call precedence" do
      as_of = ~U[2026-07-29 12:00:00Z]
      snapshot = scheduled_burn_snapshot(as_of, 60 * 60)

      scenarios = [
        {"exhausted alone", [scheduled_burn_window(as_of, "100", 2 * 60 * 60)],
         scheduled_burn_policy(), "exhausted"},
        {"threshold over last call", [scheduled_burn_window(as_of, "95", 2 * 60 * 60)],
         scheduled_burn_policy(%{trigger_mode: "threshold"}), "threshold"},
        {"last call alone", [scheduled_burn_window(as_of, "25", 2 * 60 * 60)],
         scheduled_burn_policy(), "last_call"},
        {"exhausted over threshold and last call",
         [scheduled_burn_window(as_of, "100", 2 * 60 * 60)],
         scheduled_burn_policy(%{trigger_mode: "threshold"}), "exhausted"}
      ]

      for {label, windows, policy, expected_detail} <- scenarios do
        assert {:burn, %{trigger_detail: ^expected_detail}} =
                 AutoEligibility.scheduled_burn_condition(windows, policy, snapshot, as_of),
               label
      end

      assert {:burn, %{trigger_detail: "last_call"}} =
               AutoEligibility.scheduled_burn_condition(
                 [scheduled_burn_window(as_of, "99.999", 2 * 60 * 60)],
                 scheduled_burn_policy(),
                 snapshot,
                 as_of
               )

      for {used_percent, expected} <- [
            {"94", "last_call"},
            {"95", "threshold"},
            {"96", "threshold"}
          ] do
        assert {:burn, %{trigger_detail: ^expected}} =
                 AutoEligibility.scheduled_burn_condition(
                   [scheduled_burn_window(as_of, used_percent, 2 * 60 * 60)],
                   scheduled_burn_policy(%{trigger_mode: "threshold"}),
                   snapshot,
                   as_of
                 )
      end

      assert {:burn, %{trigger_detail: "last_call"}} =
               AutoEligibility.scheduled_burn_condition(
                 [scheduled_burn_window(as_of, "95", 2 * 60 * 60)],
                 scheduled_burn_policy(%{trigger_mode: "blocked"}),
                 snapshot,
                 as_of
               )
    end

    test "pure last-call decision uses exact expiry and reset ordering boundaries" do
      as_of = ~U[2026-07-29 12:00:00.900000Z]
      policy = scheduled_burn_policy()

      for {expires_in_seconds, expected} <- [
            {90 * 60 + 1, {:not_ready, :burn_condition_absent}},
            {90 * 60, :burn},
            {1, :burn},
            {0, {:not_ready, :burn_condition_absent}},
            {-1, {:not_ready, :burn_condition_absent}}
          ] do
        snapshot = scheduled_burn_snapshot(as_of, expires_in_seconds)
        windows = [scheduled_burn_window(as_of, "25", 3 * 60 * 60)]
        result = AutoEligibility.scheduled_burn_condition(windows, policy, snapshot, as_of)

        case expected do
          :burn -> assert {:burn, %{trigger_detail: "last_call"}} = result
          not_ready -> assert ^not_ready = result
        end
      end

      snapshot = scheduled_burn_snapshot(as_of, 60 * 60)

      for {reset_delta, expected} <- [
            {1, :burn},
            {0, {:not_ready, :natural_reset_buffer}},
            {-1, {:not_ready, :natural_reset_buffer}}
          ] do
        windows = [scheduled_burn_window(as_of, "25", 60 * 60 + reset_delta)]
        result = AutoEligibility.scheduled_burn_condition(windows, policy, snapshot, as_of)

        case expected do
          :burn -> assert {:burn, %{trigger_detail: "last_call"}} = result
          not_ready -> assert ^not_ready = result
        end
      end
    end

    test "pure burn decision shares successful expiration freshness at every horizon edge" do
      as_of = ~U[2026-07-29 12:00:00.900000Z]
      policy = scheduled_burn_policy(%{min_blocked_minutes: 50 * 60})
      window = scheduled_burn_window(as_of, "100", 49 * 60 * 60)

      scenarios = [
        {86_399, 29 * 60 + 59, true},
        {86_400, 29 * 60 + 59, true},
        {86_400, 30 * 60, false},
        {86_401, 30 * 60, true}
      ]

      for {expires_in_seconds, observed_age_seconds, fresh?} <- scenarios do
        snapshot =
          scheduled_burn_snapshot(as_of, expires_in_seconds,
            observed_age_seconds: observed_age_seconds
          )

        assert SavedResets.expiration_observation_fresh?(snapshot, as_of) == fresh?

        result = AutoEligibility.scheduled_burn_condition([window], policy, snapshot, as_of)

        if fresh? do
          assert {:burn, %{trigger_detail: "exhausted"}} = result
        else
          assert {:not_ready, :expiration_stale} = result
        end
      end
    end

    test "pure burn decision keeps B1 normal buffer independent from expiration freshness" do
      as_of = ~U[2026-07-29 12:00:00Z]
      window = scheduled_burn_window(as_of, "100", 60 * 60)
      policy = scheduled_burn_policy(%{min_blocked_minutes: 60})

      for observed_age_seconds <- [30 * 60, 6 * 60 * 60] do
        snapshot =
          scheduled_burn_snapshot(as_of, 60 * 60, observed_age_seconds: observed_age_seconds)

        refute SavedResets.expiration_observation_fresh?(snapshot, as_of)

        assert {:burn, %{trigger_detail: "exhausted"}} =
                 AutoEligibility.scheduled_burn_condition([window], policy, snapshot, as_of)
      end

      for reset_in_seconds <- [60 * 60 - 1, 60 * 60, 60 * 60 + 1] do
        result =
          AutoEligibility.scheduled_burn_condition(
            [scheduled_burn_window(as_of, "100", reset_in_seconds)],
            policy,
            scheduled_burn_snapshot(as_of, 2 * 60 * 60, observed_age_seconds: 30 * 60),
            as_of
          )

        if reset_in_seconds < 60 * 60 do
          assert {:not_ready, :natural_reset_buffer} = result
        else
          assert {:burn, %{trigger_detail: "exhausted"}} = result
        end
      end
    end

    test "pure burn decision selects evidence only within the winning qualifying set" do
      as_of = ~U[2026-07-29 12:00:00Z]

      threshold_result =
        AutoEligibility.scheduled_burn_condition(
          [
            scheduled_burn_window(as_of, "99", 30 * 60),
            scheduled_burn_window(as_of, "95", 2 * 60 * 60)
          ],
          scheduled_burn_policy(%{trigger_mode: "threshold"}),
          scheduled_burn_snapshot(as_of, 2 * 60 * 60),
          as_of
        )

      assert {:burn,
              %{
                trigger_detail: "threshold",
                used_percent_at_decision: threshold_percent,
                natural_reset_at_decision: threshold_reset
              }} = threshold_result

      assert Decimal.equal?(threshold_percent, Decimal.new("95"))
      assert threshold_reset == DateTime.add(as_of, 2, :hour)

      last_call_result =
        AutoEligibility.scheduled_burn_condition(
          [
            scheduled_burn_window(as_of, "99", 30 * 60),
            scheduled_burn_window(as_of, "70", 2 * 60 * 60)
          ],
          scheduled_burn_policy(),
          scheduled_burn_snapshot(as_of, 60 * 60),
          as_of
        )

      assert {:burn,
              %{
                trigger_detail: "last_call",
                used_percent_at_decision: last_call_percent,
                natural_reset_at_decision: last_call_reset
              }} = last_call_result

      assert Decimal.equal?(last_call_percent, Decimal.new("70"))
      assert last_call_reset == DateTime.add(as_of, 2, :hour)

      ranked_result =
        AutoEligibility.scheduled_burn_condition(
          [
            scheduled_burn_window(as_of, "80", 2 * 60 * 60),
            scheduled_burn_window(as_of, "90", 90 * 60),
            scheduled_burn_window(as_of, "90.000", 3 * 60 * 60)
          ],
          scheduled_burn_policy(%{trigger_mode: "threshold", quota_threshold_percent: 80}),
          scheduled_burn_snapshot(as_of, 4 * 60 * 60),
          as_of
        )

      assert {:burn,
              %{
                trigger_detail: "threshold",
                used_percent_at_decision: ranked_percent,
                natural_reset_at_decision: ranked_reset
              }} = ranked_result

      assert Decimal.equal?(ranked_percent, Decimal.new("90"))
      assert ranked_reset == DateTime.add(as_of, 3, :hour)
    end

    test "pure burn decision returns only bounded deterministic not-ready reasons" do
      as_of = ~U[2026-07-29 12:00:00Z]
      policy = scheduled_burn_policy()

      scenarios = [
        {[], scheduled_burn_snapshot(as_of, 60 * 60), :burn_condition_absent},
        {[scheduled_burn_window(as_of, "0", 2 * 60 * 60)],
         scheduled_burn_snapshot(as_of, 60 * 60), :burn_condition_absent},
        {[scheduled_burn_window(as_of, "25", 2 * 60 * 60)],
         scheduled_burn_snapshot(as_of, 60 * 60, observed_at: "invalid"), :expiration_stale},
        {[scheduled_burn_window(as_of, "25", 30 * 60)], scheduled_burn_snapshot(as_of, 60 * 60),
         :natural_reset_buffer},
        {[scheduled_burn_window(as_of, "100", 30 * 60)],
         scheduled_burn_snapshot(as_of, 60 * 60, observed_age_seconds: 30 * 60),
         :natural_reset_buffer}
      ]

      for {windows, snapshot, reason} <- scenarios do
        assert {:not_ready, ^reason} =
                 AutoEligibility.scheduled_burn_condition(windows, policy, snapshot, as_of)
      end
    end

    test "pure burn decision requires a valid future credit expiration for every branch" do
      as_of = ~U[2026-07-29 12:00:00Z]

      for snapshot <- [
            scheduled_burn_snapshot(as_of, 0),
            scheduled_burn_snapshot(as_of, -1),
            scheduled_burn_snapshot(as_of, 60 * 60)
            |> Map.put(:next_expires_at, "invalid"),
            scheduled_burn_snapshot(as_of, 60 * 60)
            |> Map.put(:next_expires_at, nil)
          ],
          {window, policy} <- [
            {scheduled_burn_window(as_of, "100", 2 * 60 * 60), scheduled_burn_policy()},
            {scheduled_burn_window(as_of, "95", 2 * 60 * 60),
             scheduled_burn_policy(%{trigger_mode: "threshold"})},
            {scheduled_burn_window(as_of, "25", 2 * 60 * 60), scheduled_burn_policy()}
          ] do
        assert {:not_ready, :burn_condition_absent} =
                 AutoEligibility.scheduled_burn_condition([window], policy, snapshot, as_of)
      end
    end

    test "pure burn decision compares whole seconds but preserves decision evidence precision" do
      as_of = ~U[2026-07-29 12:00:00.900000Z]
      expires_at = ~U[2026-07-29 13:00:00.800000Z]
      reset_at = ~U[2026-07-29 14:00:00.700000Z]

      snapshot =
        scheduled_burn_snapshot(as_of, 60 * 60)
        |> Map.put(:next_expires_at, DateTime.to_iso8601(expires_at))

      window = %{scheduled_burn_window(as_of, "25", 2 * 60 * 60) | reset_at: reset_at}

      assert {:burn,
              %{
                trigger_detail: "last_call",
                credit_expires_at_at_decision: ^expires_at,
                natural_reset_at_decision: ^reset_at,
                decided_at: ^as_of
              }} =
               AutoEligibility.scheduled_burn_condition(
                 [window],
                 scheduled_burn_policy(),
                 snapshot,
                 as_of
               )
    end

    test "eligible scheduled rescue consumes once through the shared redemption pipeline" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture()

      assert AutoEligibility.scheduled_expiry_candidate?(identity, as_of)

      assert {:ok,
              %{
                status: :succeeded,
                applied?: true,
                code: "reset",
                identity: persisted_identity
              }} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [
               %{method: "POST", path: "/api/codex/rate-limit-reset-credits/consume"},
               %{method: "GET", path: "/api/codex/usage"}
             ] = FakeUpstream.requests(fake)

      redemption = persisted_identity.metadata["saved_reset_redemption"]
      assert redemption["trigger_kind"] == "scheduled_expiry_rescue"

      assert Map.take(redemption, scheduled_decision_metadata_keys()) == %{
               "trigger_detail" => "last_call",
               "used_percent_at_decision" => "25",
               "credit_expires_at_at_decision" =>
                 DateTime.to_iso8601(DateTime.add(as_of, 1, :hour)),
               "natural_reset_at_decision" => DateTime.to_iso8601(DateTime.add(as_of, 2, :hour)),
               "decided_at" => DateTime.to_iso8601(as_of)
             }

      refute Map.has_key?(redemption, "probe")
    end

    test "persists scheduled fields in the consuming claim before provider I/O" do
      parent = self()
      release_ref = make_ref()

      {:ok, fake} =
        FakeUpstream.start_link(
          FakeUpstream.barrier_json_response(%{"code" => "nothing_to_reset"},
            notify: parent,
            release_ref: release_ref
          )
        )

      %{as_of: as_of, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(as_of: ~U[2026-07-29 12:00:00Z], fake: fake)

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          SavedResetRedemption.redeem_scheduled_expiry(
            assignment,
            identity.id,
            started_at: as_of
          )
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, fake_request_pid,
                      ^release_ref},
                     5_000

      consuming = Repo.reload!(identity).metadata["saved_reset_redemption"]
      assert consuming["status"] == "redeeming"
      assert consuming["phase"] == "consuming"

      assert Map.keys(Map.take(consuming, scheduled_decision_metadata_keys())) |> Enum.sort() ==
               Enum.sort(scheduled_decision_metadata_keys())

      send(fake_request_pid, {:fake_upstream_release_timeout, release_ref})
      assert {:ok, %{status: :noop, code: "nothing_to_reset"}} = Task.await(task, 5_000)
    end

    test "selects highest usage then latest reset for scheduled decision evidence" do
      as_of = ~U[2026-07-29 12:00:00Z]

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(as_of: as_of, quota?: false)

      identity = update_saved_resets!(identity, %{"source" => nil})

      assert {:ok, [_lower, _earlier, _selected]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 scheduled_weekly_quota_attrs(as_of, Decimal.new("70"), quota_key: "lower"),
                 scheduled_weekly_quota_attrs(as_of, Decimal.new("80"),
                   source: "codex_response_headers",
                   reset_at: DateTime.add(as_of, 3, :hour)
                 ),
                 scheduled_weekly_quota_attrs(as_of, Decimal.new("80.000"),
                   source: "runtime",
                   reset_at: DateTime.add(as_of, 4, :hour)
                 )
               ])

      assert {:ok, %{status: :succeeded, identity: persisted_identity}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      redemption = persisted_identity.metadata["saved_reset_redemption"]
      assert redemption["used_percent_at_decision"] == "80"

      assert redemption["natural_reset_at_decision"] ==
               as_of
               |> DateTime.add(4, :hour)
               |> Map.put(:microsecond, {0, 6})
               |> DateTime.to_iso8601()

      assert Enum.any?(FakeUpstream.requests(fake), &(&1.method == "POST"))
    end

    test "preserves scheduled evidence on provider noop and failure finalization" do
      for {scenario, consume_response, expected_status} <- [
            {:noop, {200, %{"code" => "nothing_to_reset"}}, :noop},
            {:failure, {502, %{"code" => "provider_rejected"}}, :failed}
          ] do
        %{as_of: as_of, identity: identity, assignment: assignment} =
          scheduled_expiry_fixture(consume_response: consume_response)

        assert {:ok, %{status: ^expected_status, identity: persisted_identity}} =
                 SavedResetRedemption.redeem_scheduled_expiry(
                   assignment,
                   identity.id,
                   started_at: as_of
                 ),
               "scenario=#{scenario}"

        redemption = persisted_identity.metadata["saved_reset_redemption"]

        assert Map.keys(Map.take(redemption, scheduled_decision_metadata_keys())) |> Enum.sort() ==
                 Enum.sort(scheduled_decision_metadata_keys())

        assert redemption["trigger_detail"] == "last_call"
        assert redemption["used_percent_at_decision"] == "25"
      end
    end

    test "legacy redemption records remain readable without scheduled evidence fields" do
      as_of = ~U[2026-07-29 12:00:00Z]
      legacy = redemption_metadata("scheduled_expiry_rescue", DateTime.add(as_of, -5, :minute))

      for key <- scheduled_decision_metadata_keys() do
        refute Map.has_key?(legacy, key)
      end

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(as_of: as_of, redemption: legacy)

      assert {:ok, %{status: :noop, code: "scheduled_expiry_redemption_stale"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == legacy
      assert FakeUpstream.requests(fake) == []
    end

    test "scheduled rescue noops when policy is disabled under lock" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(policy_enabled?: false)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "scheduled_expiry_policy_disabled"
              }} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue noops when count is at the keep-credit floor" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(policy_attrs: %{saved_reset_auto_redeem_keep_credits: 1})

      assert {:ok, %{status: :noop, applied?: false, code: "scheduled_expiry_keep_credits"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue noops for missing, expired, or outside-window expiration" do
      for {scenario, expires_in_seconds} <- [
            missing: nil,
            expired: -1,
            outside_window: 24 * 60 * 60 + 1
          ] do
        %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
          scheduled_expiry_fixture(expires_in_seconds: expires_in_seconds)

        assert {:ok, %{status: :noop, applied?: false, code: "scheduled_expiry_not_expiring"}} =
                 SavedResetRedemption.redeem_scheduled_expiry(
                   assignment,
                   identity.id,
                   started_at: as_of
                 ),
               "scenario=#{scenario}"

        assert FakeUpstream.requests(fake) == [], "scenario=#{scenario}"
      end
    end

    test "scheduled rescue noops when the burn condition is absent" do
      scenarios = [
        {:absent, [quota?: false]},
        {:unused, [quota_used_percent: Decimal.new("0")]},
        {:stale,
         [
           quota_overrides: %{
             observed_at: DateTime.add(DateTime.utc_now(), -20, :minute),
             last_sync_at: DateTime.add(DateTime.utc_now(), -20, :minute)
           }
         ]},
        {:source_mismatch, [quota_overrides: %{source: "codex_response_headers"}]}
      ]

      for {scenario, opts} <- scenarios do
        %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
          scheduled_expiry_fixture(opts)

        assert {:ok,
                %{
                  status: :noop,
                  applied?: false,
                  code: "scheduled_expiry_burn_not_ready"
                }} =
                 SavedResetRedemption.redeem_scheduled_expiry(
                   assignment,
                   identity.id,
                   started_at: as_of
                 ),
               "scenario=#{scenario}"

        assert FakeUpstream.requests(fake) == [], "scenario=#{scenario}"
      end
    end

    test "scheduled weekly eligibility returns every usable window with its evidence" do
      as_of = ~U[2026-07-29 12:00:00Z]

      %{identity: identity} = scheduled_expiry_fixture(as_of: as_of, quota?: false)

      first_reset_at = DateTime.add(as_of, 2, :hour)
      second_reset_at = DateTime.add(as_of, 3, :hour)
      stale_at = DateTime.add(as_of, -Evidence.freshness_ttl_seconds(), :second)

      windows = [
        scheduled_weekly_quota_attrs(as_of, Decimal.new("25"), reset_at: first_reset_at),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("50"),
          source: "codex_response_headers",
          reset_at: second_reset_at
        ),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("0"), quota_key: "zero-use"),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("10"),
          quota_key: "stale",
          observed_at: stale_at,
          last_sync_at: stale_at
        ),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("10"),
          quota_key: "missing-reset",
          reset_at: nil
        ),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("10"),
          quota_key: "past-reset",
          reset_at: DateTime.add(as_of, -1, :second)
        ),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("10"),
          quota_key: "far-reset",
          reset_at: DateTime.add(as_of, 7 * 24 * 60 * 60 + 60 * 60 + 1, :second)
        ),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("10"),
          quota_key: "source-mismatch",
          source: "codex_response_headers"
        ),
        scheduled_weekly_quota_attrs(as_of, Decimal.new("10"),
          quota_key: "primary",
          window_kind: "primary",
          window_minutes: 300
        )
      ]

      assert {:ok, persisted_windows} = QuotaWindows.upsert_quota_windows(identity, windows)
      snapshot = identity |> SavedResets.snapshot(as_of) |> Map.put(:source, nil)

      assert {:eligible, selected_windows} =
               AutoEligibility.scheduled_weekly_eligibility(persisted_windows, snapshot, as_of)

      assert Enum.map(selected_windows, & &1.id) ==
               persisted_windows
               |> Enum.filter(
                 &(&1.source in ["codex_usage_api", "codex_response_headers"] and
                     (Decimal.equal?(&1.used_percent, Decimal.new("25")) or
                        Decimal.equal?(&1.used_percent, Decimal.new("50"))))
               )
               |> Enum.map(& &1.id)

      assert Enum.any?(selected_windows, fn window ->
               Decimal.equal?(window.used_percent, Decimal.new("25")) and
                 DateTime.compare(window.reset_at, first_reset_at) == :eq
             end)

      assert Enum.any?(selected_windows, fn window ->
               Decimal.equal?(window.used_percent, Decimal.new("50")) and
                 DateTime.compare(window.reset_at, second_reset_at) == :eq
             end)

      assert Enum.all?(selected_windows, &(&1 in persisted_windows))
    end

    test "scheduled weekly eligibility is unavailable for empty or unusable evidence" do
      as_of = ~U[2026-07-29 12:00:00Z]

      for {scenario, overrides} <- [
            zero_use: [used_percent: Decimal.new("0")],
            stale: [
              observed_at: DateTime.add(as_of, -20, :minute),
              last_sync_at: DateTime.add(as_of, -20, :minute)
            ],
            invalid_reset: [reset_at: nil],
            past_reset: [reset_at: DateTime.add(as_of, -1, :second)],
            far_future_reset: [
              reset_at: DateTime.add(as_of, 7 * 24 * 60 * 60 + 60 * 60 + 1, :second)
            ],
            source_incompatible: [source: "codex_response_headers"],
            inferred_precision: [source_precision: "inferred"],
            unknown_precision: [source_precision: "unknown"]
          ] do
        %{identity: identity} = scheduled_expiry_fixture(as_of: as_of, quota?: false)

        attrs =
          scheduled_weekly_quota_attrs(
            as_of,
            Keyword.get(overrides, :used_percent, Decimal.new("25")),
            Keyword.drop(overrides, [:used_percent])
          )

        assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
        windows = QuotaWindows.list_evidence(identity)

        assert :unavailable =
                 AutoEligibility.scheduled_weekly_eligibility(
                   windows,
                   SavedResets.snapshot(identity, as_of),
                   as_of
                 ),
               "scenario=#{scenario}"
      end

      %{identity: identity} = scheduled_expiry_fixture(as_of: as_of, quota?: false)

      assert :unavailable =
               AutoEligibility.scheduled_weekly_eligibility(
                 QuotaWindows.list_evidence(identity),
                 SavedResets.snapshot(identity, as_of),
                 as_of
               )
    end

    test "scheduled rescue rejects a superseded legacy weekly source before source filtering" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(quota?: false)

      stale_at = DateTime.add(as_of, -2 * Evidence.freshness_ttl_seconds(), :second)

      assert {:ok, [_legacy, _current]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 weekly_quota_attrs(Decimal.new("25"),
                   window_kind: "primary",
                   observed_at: stale_at,
                   last_sync_at: stale_at
                 ),
                 weekly_quota_attrs(Decimal.new("0"),
                   source: "codex_response_headers",
                   observed_at: as_of,
                   last_sync_at: as_of
                 )
               ])

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "scheduled_expiry_burn_not_ready"
              }} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue noops when the natural reset is inside the configured buffer" do
      as_of = ~U[2026-07-29 12:00:00Z]

      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          as_of: as_of,
          quota?: false
        )

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 scheduled_weekly_quota_attrs(
                   as_of,
                   Decimal.new("25"),
                   reset_at: DateTime.add(as_of, 59, :minute)
                 )
               ])

      assert {:eligible, [_window]} =
               AutoEligibility.scheduled_weekly_eligibility(
                 QuotaWindows.list_evidence(identity),
                 SavedResets.snapshot(identity, as_of),
                 as_of
               )

      refute AutoEligibility.scheduled_expiry_candidate?(identity, as_of)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "scheduled_expiry_natural_reset_buffer"
              }} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "pure, pre-lock, and locked scheduled decisions agree on bounded reasons" do
      as_of = ~U[2026-07-29 12:00:00Z]

      scenarios = [
        {:burn_condition_absent, "scheduled_expiry_burn_not_ready",
         [quota_used_percent: Decimal.new("0")]},
        {:expiration_stale, "scheduled_expiry_expiration_stale", [stale_expiration?: true]},
        {:natural_reset_buffer, "scheduled_expiry_natural_reset_buffer",
         [quota_overrides: %{reset_at: DateTime.add(as_of, 30, :minute)}]}
      ]

      for {expected_reason, expected_code, opts} <- scenarios do
        %{fake: fake, identity: identity, assignment: assignment} =
          scheduled_expiry_fixture(Keyword.put(opts, :as_of, as_of))

        identity =
          if Keyword.get(opts, :stale_expiration?, false) do
            update_saved_resets!(identity, %{
              "expires_observed_at" => DateTime.to_iso8601(DateTime.add(as_of, -30, :minute))
            })
          else
            identity
          end

        policy = SavedResets.auto_policy(identity)
        snapshot = SavedResets.snapshot(identity, as_of)
        windows = QuotaWindows.list_evidence(identity)

        assert {:not_ready, ^expected_reason} =
                 AutoEligibility.scheduled_burn_condition(windows, policy, snapshot, as_of)

        refute AutoEligibility.scheduled_expiry_candidate?(identity, as_of)

        assert {:noop, ^expected_code} =
                 AutoEligibility.validate_locked_scheduled_expiry(
                   identity,
                   assignment,
                   identity.id,
                   as_of,
                   SavedResets.redemption_receive_timeout_ms()
                 )

        assert [] = FakeUpstream.requests(fake)
      end
    end

    @tag :separate_backend_scheduled_expiry_lock_time
    test "production default resolves scheduled decision time after both row locks" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_scheduled_expiry_race_fixture!(fake)
      on_exit(fn -> cleanup_committed_scheduled_expiry_race_fixture!(fixture) end)

      decision_before = DateTime.utc_now() |> DateTime.add(3, :second)
      expires_at = DateTime.add(decision_before, 1, :second)
      assignment_id = List.first(fixture.assignment_ids)

      run_unboxed(fn ->
        identity = Repo.get!(UpstreamIdentity, fixture.identity_id)
        metadata = identity.metadata || %{}

        identity
        |> UpstreamIdentity.changeset(%{
          metadata:
            Map.put(
              metadata,
              "saved_resets",
              scheduled_saved_resets(decision_before, 1)
            )
        })
        |> Repo.update!()
      end)

      parent = self()
      barrier = make_ref()

      assignment_holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              backend_pid = backend_pid!()

              Repo.one!(
                from assignment in PoolUpstreamAssignment,
                  where: assignment.id == ^assignment_id,
                  lock: "FOR UPDATE"
              )

              send(parent, {barrier, :assignment_locked, backend_pid})

              receive do
                {^barrier, :release_assignment} -> :released
              after
                10_000 -> raise "timed out waiting to release scheduled assignment lock"
              end
            end)
          end)
        end)

      try do
        assert_receive {^barrier, :assignment_locked, holder_backend_pid}, 5_000

        redemption_task =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              send(parent, {barrier, :redemption_backend, backend_pid!()})
              SavedResetRedemption.redeem_scheduled_expiry(assignment_id, fixture.identity_id)
            end)
          end)

        assert_receive {^barrier, :redemption_backend, redemption_backend_pid}, 5_000

        observation = observe_blocked_probe_claim!(redemption_backend_pid, holder_backend_pid)
        assert holder_backend_pid in observation.blocking_pids
        assert observation.wait_event_type == "Lock"

        await_after!(expires_at)
        send(assignment_holder.pid, {barrier, :release_assignment})

        assert {:ok, :released} = Task.await(assignment_holder, 5_000)

        assert {:ok, %{status: :noop, code: "scheduled_expiry_not_expiring"}} =
                 Task.await(redemption_task, 5_000)

        persisted = run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end)
        refute Map.has_key?(persisted.metadata || %{}, "saved_reset_redemption")
        assert [] = FakeUpstream.requests(fake)

        assert {:ok, %{status: :succeeded, identity: explicit_identity}} =
                 run_unboxed(fn ->
                   SavedResetRedemption.redeem_scheduled_expiry(
                     assignment_id,
                     fixture.identity_id,
                     started_at: decision_before
                   )
                 end)

        assert explicit_identity.metadata["saved_reset_redemption"]["decided_at"] ==
                 DateTime.to_iso8601(decision_before)

        assert Enum.any?(FakeUpstream.requests(fake), &(&1.method == "POST"))
      after
        send(assignment_holder.pid, {barrier, :release_assignment})
      end
    end

    test "fresh competing automatic claim remains in progress" do
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          as_of: as_of,
          redemption: redemption_metadata("scheduled_expiry_rescue", as_of)
        )

      assert {:error, :redemption_in_progress} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "legacy scheduled claim freshness is strict before and under lock" do
      as_of = ~U[2026-07-29 12:00:00.000000Z]

      for {age_ms, expected_candidate?, expected_state} <- [
            {74_999, false, :in_progress},
            {75_000, false, :stale}
          ] do
        %{fake: fake, identity: identity, assignment: assignment} =
          scheduled_expiry_fixture(
            as_of: as_of,
            redemption:
              redemption_metadata(
                "scheduled_expiry_rescue",
                DateTime.add(as_of, -age_ms, :millisecond)
              )
          )

        assert AutoEligibility.scheduled_expiry_candidate?(identity, as_of) == expected_candidate?

        result =
          SavedResetRedemption.redeem_scheduled_expiry(
            assignment,
            identity.id,
            started_at: as_of
          )

        case expected_state do
          :in_progress ->
            assert {:error, :redemption_in_progress} = result

          :stale ->
            assert {:ok,
                    %{
                      status: :noop,
                      applied?: false,
                      code: "scheduled_expiry_redemption_stale"
                    }} = result
        end

        assert [] = FakeUpstream.requests(fake)
      end
    end

    test "stale automatic claim stays fail-closed for manual recovery" do
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          as_of: as_of,
          redemption:
            redemption_metadata(
              "scheduled_expiry_rescue",
              DateTime.add(as_of, -5, :minute)
            )
        )

      assert {:ok, %{status: :noop, applied?: false, code: "scheduled_expiry_redemption_stale"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "unknown lifecycle remains fail-closed" do
      redemption = %{
        "status" => "redeeming",
        "phase" => "future_lifecycle",
        "attempt_id" => Ecto.UUID.generate(),
        "generation" => 1,
        "trigger_kind" => "scheduled_expiry_rescue",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "result" => nil
      }

      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(redemption: redemption)

      assert {:ok,
              %{status: :noop, applied?: false, code: "scheduled_expiry_lifecycle_unavailable"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "automatic consume latch noops before provider HTTP" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          redemption: applied_gateway_auto_redemption("confirmed_by_quota", 5)
        )

      assert {:ok, %{status: :noop, applied?: false, code: "scheduled_expiry_consume_latched"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue noops when the expected identity is inactive" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture()

      update_identity!(identity, %{status: UpstreamIdentity.paused_status()})

      assert {:ok,
              %{status: :noop, applied?: false, code: "scheduled_expiry_identity_unavailable"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue noops when the assignment is inactive" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture()

      update_assignment!(assignment, %{status: PoolUpstreamAssignment.paused_status()})

      assert {:ok,
              %{status: :noop, applied?: false, code: "scheduled_expiry_assignment_unavailable"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue noops after assignment reassignment" do
      %{as_of: as_of, fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture()

      foreign_identity = active_upstream_identity_fixture()
      update_assignment!(assignment, %{upstream_identity_id: foreign_identity.id})

      assert {:ok, %{status: :noop, applied?: false, code: "scheduled_expiry_identity_mismatch"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue noops when the expected identity does not own the assignment" do
      %{as_of: as_of, fake: fake, assignment: assignment} = scheduled_expiry_fixture()
      foreign_identity = active_upstream_identity_fixture()

      assert {:ok, %{status: :noop, applied?: false, code: "scheduled_expiry_identity_mismatch"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 foreign_identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "scheduled rescue safely rejects a malformed expected identity id" do
      %{as_of: as_of, fake: fake, assignment: assignment} = scheduled_expiry_fixture()

      assert {:ok,
              %{status: :noop, applied?: false, code: "scheduled_expiry_identity_unavailable"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 "not-a-uuid",
                 started_at: as_of
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

    @tag :separate_backend_scheduled_expiry_race
    test "scheduled sibling claims serialize across separate PostgreSQL backends" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_scheduled_expiry_race_fixture!(fake)
      on_exit(fn -> cleanup_committed_scheduled_expiry_race_fixture!(fixture) end)

      {winner_result, loser_result, winner_backend_pid, loser_backend_pid} =
        run_automatic_claim_race!(
          fixture,
          fn assignment_id ->
            SavedResetRedemption.redeem_scheduled_expiry(
              assignment_id,
              fixture.identity_id,
              started_at: fixture.as_of,
              receive_timeout: 15_000
            )
          end,
          fn assignment_id ->
            SavedResetRedemption.redeem_scheduled_expiry(
              assignment_id,
              fixture.identity_id,
              started_at: fixture.as_of,
              receive_timeout: 15_000
            )
          end
        )

      assert winner_backend_pid != loser_backend_pid
      assert {:ok, %{status: :succeeded, applied?: true}} = winner_result
      assert {:error, :redemption_in_progress} = loser_result
      assert provider_consume_count(fake) == 1
    end

    @tag :separate_backend_automatic_claimant_race
    test "scheduled and gateway automatic claims share the identity consume latch" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_scheduled_expiry_race_fixture!(fake)
      on_exit(fn -> cleanup_committed_scheduled_expiry_race_fixture!(fixture) end)

      gateway_assignment_id = List.last(fixture.assignment_ids)

      {scheduled_result, gateway_result, scheduled_backend_pid, gateway_backend_pid} =
        run_automatic_claim_race!(
          fixture,
          fn assignment_id ->
            SavedResetRedemption.redeem_scheduled_expiry(
              assignment_id,
              fixture.identity_id,
              started_at: fixture.as_of,
              receive_timeout: 15_000
            )
          end,
          fn _assignment_id ->
            assignment = Repo.get!(PoolUpstreamAssignment, gateway_assignment_id)
            identity = Repo.get!(UpstreamIdentity, fixture.identity_id)

            SavedResetRedemption.redeem(assignment,
              trigger_kind: "gateway_auto",
              gateway_auto_context: gateway_auto_context(assignment, identity, :expiring_reset),
              started_at: fixture.as_of,
              receive_timeout: 15_000
            )
          end
        )

      assert scheduled_backend_pid != gateway_backend_pid
      assert {:ok, %{status: :succeeded, applied?: true}} = scheduled_result
      assert {:error, :redemption_in_progress} = gateway_result
      assert provider_consume_count(fake) == 1

      if System.get_env("TASK5_MANUAL_QA") == "1" do
        IO.puts(
          "TASK5_AUTO_RACE backend_pids=#{scheduled_backend_pid},#{gateway_backend_pid} " <>
            "consume_count=#{provider_consume_count(fake)}"
        )
      end
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
    test "consume cooldown stays latched at cooldown-1ms and clears at equality" do
      as_of = ~U[2026-07-25 12:00:00.000000Z]
      cooldown_ms = RedemptionLifecycle.gateway_auto_consume_cooldown_ms()

      redemption = %{
        "status" => "succeeded",
        "phase" => "confirmed_by_quota",
        "consumed_at" => DateTime.to_iso8601(as_of),
        "result" => %{"applied" => true}
      }

      assert RedemptionLifecycle.gateway_auto_latch(
               redemption,
               DateTime.add(as_of, cooldown_ms - 1, :millisecond)
             ) == :cooldown

      assert RedemptionLifecycle.gateway_auto_latch(
               redemption,
               DateTime.add(as_of, cooldown_ms, :millisecond)
             ) == :clear
    end

    test "saved-reset expiration uses the scan timestamp at before, equality, and after" do
      as_of = ~U[2026-07-25 12:00:00.000000Z]

      metadata_for = fn expires_at ->
        %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "next_expires_at" => DateTime.to_iso8601(expires_at)
          }
        }
      end

      refute SavedResets.expires_soon?(metadata_for.(DateTime.add(as_of, -1, :second)), as_of)
      assert SavedResets.expires_soon?(metadata_for.(as_of), as_of)
      assert SavedResets.expires_soon?(metadata_for.(DateTime.add(as_of, 1, :second)), as_of)
    end

    test "natural-reset minimum blocks at min-1s and redeems from equality through the maximum" do
      as_of = ~U[2026-07-18 12:00:00.000000Z]
      policy = %{min_blocked_minutes: 60}

      window = %AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(as_of, 60 * 60 - 1, :second),
        source: "codex_usage_api",
        source_precision: "observed",
        freshness_state: "fresh",
        observed_at: as_of
      }

      refute AutoEligibility.blocked_weekly_exhaustion?([window], policy, as_of)

      assert AutoEligibility.blocked_weekly_exhaustion?(
               [%{window | reset_at: DateTime.add(as_of, 60, :minute)}],
               policy,
               as_of
             )

      assert AutoEligibility.blocked_weekly_exhaustion?(
               [%{window | reset_at: DateTime.add(as_of, 7 * 24 * 60 * 60 + 60 * 60, :second)}],
               policy,
               as_of
             )
    end

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

  defp scheduled_expiry_fixture(opts \\ []) do
    as_of =
      Keyword.get_lazy(opts, :as_of, fn ->
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      end)

    fake =
      case Keyword.fetch(opts, :fake) do
        {:ok, fake} ->
          fake

        :error ->
          {:ok, fake} =
            FakeUpstream.start_link(
              {:path_json,
               %{
                 "/api/codex/rate-limit-reset-credits/consume" =>
                   Keyword.get(opts, :consume_response, {200, %{"code" => "reset"}}),
                 "/api/codex/usage" => Keyword.get(opts, :usage_response, {200, usage_payload(0)})
               }}
            )

          fake
      end

    saved_resets =
      scheduled_saved_resets(
        as_of,
        Keyword.get(opts, :expires_in_seconds, 60 * 60)
      )

    %{identity: identity, assignment: assignment} =
      assignment_with_fake(fake, "/api/codex/usage", "codex_api",
        saved_resets: saved_resets,
        redemption: Keyword.get(opts, :redemption)
      )

    identity =
      if Keyword.get(opts, :policy_enabled?, true) do
        enable_saved_reset_auto_redeem!(
          identity,
          Keyword.get(opts, :policy_attrs, %{})
        )
      else
        identity
      end

    if Keyword.get(opts, :quota?, true) do
      quota_overrides =
        %{
          observed_at: as_of,
          last_sync_at: as_of,
          reset_at: DateTime.add(as_of, 2, :hour)
        }
        |> Map.merge(Keyword.get(opts, :quota_overrides, %{}))

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 weekly_quota_attrs(
                   Keyword.get(opts, :quota_used_percent, Decimal.new("25")),
                   Map.to_list(quota_overrides)
                 )
               ])
    end

    %{as_of: as_of, fake: fake, identity: identity, assignment: assignment}
  end

  defp scheduled_saved_resets(as_of, nil) do
    scheduled_saved_resets(as_of, 60 * 60)
    |> Map.merge(%{
      "available_expires_at" => [],
      "available_expirations" => [],
      "next_expires_at" => nil
    })
  end

  defp scheduled_saved_resets(as_of, expires_in_seconds)
       when is_integer(expires_in_seconds) do
    observed_at = DateTime.to_iso8601(as_of)
    expires_at = as_of |> DateTime.add(expires_in_seconds, :second) |> DateTime.to_iso8601()

    %{
      "status" => "reported",
      "available_count" => 1,
      "source" => "codex_usage_api",
      "path_style" => "codex_api",
      "observed_at" => observed_at,
      "usage_path" => "/api/codex/usage",
      "available_expires_at" => [expires_at],
      "available_expirations" => [
        %{"expires_at" => expires_at, "first_seen_at" => observed_at}
      ],
      "next_expires_at" => expires_at,
      "expires_observed_at" => observed_at,
      "expires_refresh_attempted_at" => observed_at,
      "reason" => nil
    }
  end

  defp scheduled_burn_snapshot(as_of, expires_in_seconds, opts \\ []) do
    saved_resets = scheduled_saved_resets(as_of, expires_in_seconds)

    observed_at =
      case Keyword.fetch(opts, :observed_at) do
        {:ok, observed_at} ->
          observed_at

        :error ->
          DateTime.to_iso8601(
            DateTime.add(as_of, -Keyword.get(opts, :observed_age_seconds, 0), :second)
          )
      end

    saved_resets = Map.put(saved_resets, "expires_observed_at", observed_at)
    SavedResets.snapshot(%{"saved_resets" => saved_resets}, as_of)
  end

  defp scheduled_burn_policy(overrides \\ %{}) do
    Map.merge(
      %{
        enabled?: true,
        min_blocked_minutes: 60,
        keep_credits: 0,
        trigger_mode: "blocked",
        quota_threshold_percent: 95
      },
      overrides
    )
  end

  defp scheduled_burn_window(as_of, used_percent, reset_in_seconds) do
    %AccountQuotaWindow{
      used_percent: Decimal.new(used_percent),
      reset_at: DateTime.add(as_of, reset_in_seconds, :second)
    }
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

  defp scheduled_weekly_quota_attrs(as_of, used_percent, overrides) do
    weekly_quota_attrs(
      used_percent,
      Keyword.merge(
        [
          observed_at: as_of,
          last_sync_at: as_of,
          reset_at: DateTime.add(as_of, 2, :hour)
        ],
        overrides
      )
    )
  end

  defp scheduled_decision_atom_keys do
    [
      :credit_expires_at_at_decision,
      :decided_at,
      :natural_reset_at_decision,
      :trigger_detail,
      :used_percent_at_decision
    ]
  end

  defp scheduled_decision_metadata_keys do
    ~w(
      credit_expires_at_at_decision
      decided_at
      natural_reset_at_decision
      trigger_detail
      used_percent_at_decision
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

  defp committed_scheduled_expiry_race_fixture!(fake) do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive])
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      first_pool = pool_fixture(%{slug: "scheduled-race-a-#{unique}"})

      %{assignment: first_assignment, identity: identity} =
        active_upstream_assignment_fixture(first_pool, %{
          account_label: "Scheduled race account #{unique}",
          chatgpt_account_id: "acct_scheduled_race_#{unique}",
          metadata: %{
            "usage_base_url" => FakeUpstream.url(fake),
            "saved_resets" => scheduled_saved_resets(as_of, 60 * 60)
          }
        })

      identity = enable_saved_reset_auto_redeem!(identity)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 weekly_quota_attrs(Decimal.new("25"),
                   observed_at: as_of,
                   last_sync_at: as_of,
                   reset_at: DateTime.add(as_of, 2, :hour)
                 )
               ])

      second_pool = pool_fixture(%{slug: "scheduled-race-b-#{unique}"})

      assert {:ok, second_assignment} =
               PoolAssignments.create_pool_assignment(second_pool, identity, %{
                 assignment_label: "Scheduled race sibling #{unique}"
               })

      assert {:ok, second_assignment} =
               PoolAssignments.activate_pool_assignment(second_assignment, %{
                 skip_quota_priming: true
               })

      %{
        as_of: as_of,
        assignment_ids: [first_assignment.id, second_assignment.id],
        identity_id: identity.id,
        pool_ids: [first_pool.id, second_pool.id]
      }
    end)
  end

  defp cleanup_committed_scheduled_expiry_race_fixture!(fixture) do
    run_unboxed(fn ->
      Repo.delete_all(
        from identity in UpstreamIdentity,
          where: identity.id == ^fixture.identity_id
      )

      Repo.delete_all(from pool in Pool, where: pool.id in ^fixture.pool_ids)
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

  defp run_automatic_claim_race!(fixture, winner_fun, loser_fun) do
    parent = self()
    barrier = make_ref()
    [winner_assignment_id, loser_assignment_id] = fixture.assignment_ids

    winner_task =
      start_automatic_claim_task(
        parent,
        barrier,
        :winner,
        winner_assignment_id,
        winner_fun
      )

    loser_task =
      start_automatic_claim_task(parent, barrier, :loser, loser_assignment_id, loser_fun)

    tasks = [winner_task, loser_task]

    try do
      assert_receive {^barrier, :claim_ready, :winner, winner_backend_pid}, 5_000
      assert_receive {^barrier, :claim_ready, :loser, loser_backend_pid}, 5_000
      assert winner_backend_pid != loser_backend_pid

      handler_id = "saved-reset-automatic-lock-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == winner_task.pid and probe_identity_lock_query?(metadata) and
                 is_nil(Process.get({__MODULE__, barrier, :winner_paused})) do
              Process.put({__MODULE__, barrier, :winner_paused}, true)
              send(parent, {barrier, :winner_lock_acquired})

              receive do
                {^barrier, :release_winner} -> :ok
              after
                5_000 -> raise "timed out waiting to release automatic saved-reset winner"
              end
            end
          end,
          nil
        )

      try do
        send(winner_task.pid, {barrier, :start_claim})
        assert_receive {^barrier, :winner_lock_acquired}, 5_000

        send(loser_task.pid, {barrier, :start_claim})
        assert_receive {^barrier, :claim_started, :loser, ^loser_backend_pid}, 5_000

        observation = observe_blocked_probe_claim!(loser_backend_pid, winner_backend_pid)
        assert winner_backend_pid in observation.blocking_pids

        send(winner_task.pid, {barrier, :release_winner})

        {:winner, ^winner_backend_pid, winner_result} = Task.await(winner_task, 15_000)
        {:loser, ^loser_backend_pid, loser_result} = Task.await(loser_task, 15_000)

        {winner_result, loser_result, winner_backend_pid, loser_backend_pid}
      after
        :telemetry.detach(handler_id)
      end
    after
      release_probe_claim_tasks(tasks, barrier)
    end
  end

  defp start_automatic_claim_task(parent, barrier, role, assignment_id, claim_fun) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()
        send(parent, {barrier, :claim_ready, role, backend_pid})

        receive do
          {^barrier, :start_claim} -> :ok
        after
          5_000 -> raise "timed out waiting to start automatic saved-reset claim"
        end

        send(parent, {barrier, :claim_started, role, backend_pid})
        {role, backend_pid, claim_fun.(assignment_id)}
      end)
    end)
  end

  defp provider_consume_count(fake) do
    fake
    |> FakeUpstream.requests()
    |> Enum.count(&(&1.path == "/api/codex/rate-limit-reset-credits/consume"))
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

  defp await_after!(%DateTime{} = timestamp) do
    wait_ms = max(DateTime.diff(timestamp, DateTime.utc_now(), :millisecond) + 50, 0)

    receive do
    after
      wait_ms -> :ok
    end
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
