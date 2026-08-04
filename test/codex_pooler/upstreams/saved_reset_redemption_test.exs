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
    @tag :saved_reset_redemption_cause
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

    test "persists the ChatGPT target and dispatch reservation before the consume POST" do
      parent = self()
      release_ref = make_ref()

      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [%{"id" => "credit_reserved", "status" => "available"}],
                  "available_count" => 1
                }},
             "/backend-api/wham/rate-limit-reset-credits/consume" =>
               FakeUpstream.barrier_json_response(%{"code" => "already_redeemed"},
                 notify: parent,
                 release_ref: release_ref
               ),
             "/backend-api/wham/usage" => {200, usage_payload(0)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          SavedResetRedemption.redeem(assignment)
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, fake_request_pid,
                      ^release_ref},
                     5_000

      reserved = Repo.reload!(identity).metadata
      replay = reserved["saved_reset_redemption"]["provider_replay"]
      locator = reserved["saved_reset_redemption_target"]

      assert replay["version"] == 1
      assert replay["endpoint_family"] == "chatgpt_api"
      assert replay["provider_dispatches"] == 1
      assert replay["last_code"] == "dispatch_reserved"
      assert replay["scope_fingerprint"] =~ ~r/\A[0-9a-f]{64}\z/
      assert is_binary(locator)
      refute locator =~ "credit_reserved"

      assert %PoolUpstreamAssignment{status: status} =
               update_assignment!(assignment, %{
                 status: PoolUpstreamAssignment.paused_status()
               })

      assert status == PoolUpstreamAssignment.paused_status()

      send(fake_request_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:ok, %{status: :succeeded, applied?: true, code: "already_redeemed"}} =
               Task.await(task, 5_000)

      settled = Repo.reload!(identity).metadata
      refute Map.has_key?(settled, "saved_reset_redemption_target")
      assert settled["saved_reset_redemption"]["provider_replay"]["provider_dispatches"] == 1
    end

    test "revalidates assignment status before reserving a provider dispatch" do
      parent = self()
      release_ref = make_ref()

      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               FakeUpstream.barrier_json_response(
                 %{
                   "credits" => [%{"id" => "credit_assignment_cas", "status" => "available"}],
                   "available_count" => 1
                 },
                 notify: parent,
                 release_ref: release_ref
               ),
             "/backend-api/wham/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          SavedResetRedemption.redeem(assignment)
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, fake_request_pid,
                      ^release_ref},
                     5_000

      update_assignment!(assignment, %{status: PoolUpstreamAssignment.paused_status()})
      send(fake_request_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:error, :saved_reset_dispatch_reservation_invalid} = Task.await(task, 5_000)

      assert [%{method: "GET", path: "/backend-api/wham/rate-limit-reset-credits"}] =
               FakeUpstream.requests(fake)

      metadata = Repo.reload!(identity).metadata
      assert metadata["saved_reset_redemption"]["provider_replay"]["provider_dispatches"] == 0
      refute Map.has_key?(metadata, "saved_reset_redemption_target")
    end

    test "revalidates assignment ownership before reserving a provider dispatch" do
      parent = self()
      release_ref = make_ref()

      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               FakeUpstream.barrier_json_response(
                 %{
                   "credits" => [
                     %{"id" => "credit_assignment_owner_cas", "status" => "available"}
                   ],
                   "available_count" => 1
                 },
                 notify: parent,
                 release_ref: release_ref
               ),
             "/backend-api/wham/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      foreign_identity = active_upstream_identity_fixture()

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          SavedResetRedemption.redeem(assignment)
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, fake_request_pid,
                      ^release_ref},
                     5_000

      update_assignment!(assignment, %{upstream_identity_id: foreign_identity.id})
      send(fake_request_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:error, :saved_reset_dispatch_reservation_invalid} = Task.await(task, 5_000)

      assert [%{method: "GET", path: "/backend-api/wham/rate-limit-reset-credits"}] =
               FakeUpstream.requests(fake)

      metadata = Repo.reload!(identity).metadata
      assert metadata["saved_reset_redemption"]["provider_replay"]["provider_dispatches"] == 0
      refute Map.has_key?(metadata, "saved_reset_redemption_target")
    end

    test "preserves the reserved attempt when the consume outcome is ambiguous" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => :close_before_headers
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               SavedResetRedemption.redeem(assignment)

      redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
      assert redemption["status"] == "redeeming"
      assert redemption["phase"] == "consuming"
      assert redemption["result"] == nil
      assert redemption["provider_replay"]["provider_dispatches"] == 1
      assert redemption["provider_replay"]["last_code"] == "transport_error"

      assert [%{method: "POST", json: %{"redeem_request_id" => request_id}}] =
               FakeUpstream.requests(fake)

      assert is_binary(request_id)

      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(assignment)
      assert length(FakeUpstream.requests(fake)) == 1
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == redemption
    end

    test "an ambiguous ChatGPT consume retains its encrypted target and cannot retarget" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [
                    %{"id" => "credit_original", "status" => "available"},
                    %{"id" => "credit_other", "status" => "available"}
                  ],
                  "available_count" => 2
                }},
             "/backend-api/wham/rate-limit-reset-credits/consume" =>
               {503, %{"code" => "provider_rejected"}}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               SavedResetRedemption.redeem(assignment)

      metadata = Repo.reload!(identity).metadata
      redemption = metadata["saved_reset_redemption"]
      locator = metadata["saved_reset_redemption_target"]

      assert redemption["status"] == "redeeming"
      assert redemption["phase"] == "consuming"
      assert redemption["result"] == nil
      assert redemption["provider_replay"]["provider_dispatches"] == 1
      assert is_binary(locator)

      metadata_json = Jason.encode!(metadata)
      refute metadata_json =~ "credit_original"
      refute metadata_json =~ "credit_other"

      assert [list_request, consume_request] = FakeUpstream.requests(fake)
      assert list_request.method == "GET"
      assert consume_request.json["credit_id"] == "credit_original"

      FakeUpstream.set_mode(fake, {:path_json, %{}})

      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(assignment)
      assert FakeUpstream.requests(fake) == [list_request, consume_request]

      retained = Repo.reload!(identity).metadata
      assert retained["saved_reset_redemption_target"] == locator
      assert retained["saved_reset_redemption"] == redemption
    end

    test "stale recovery replays only the encrypted ChatGPT target with the original request id" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [
                    %{"id" => "credit_original", "status" => "available"},
                    %{"id" => "credit_other", "status" => "available"}
                  ],
                  "available_count" => 2
                }},
             "/backend-api/wham/rate-limit-reset-credits/consume" =>
               {503, %{"code" => "provider_failed"}},
             "/backend-api/wham/usage" => {200, usage_payload(0)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               SavedResetRedemption.redeem(assignment)

      [_, first_consume] = FakeUpstream.requests(fake)
      persisted = Repo.reload!(identity)
      redemption = persisted.metadata["saved_reset_redemption"]

      {:ok, first_dispatched_at, 0} =
        DateTime.from_iso8601(redemption["provider_replay"]["last_provider_dispatched_at"])

      recovery_now = DateTime.add(first_dispatched_at, 60, :second)

      due_redemption =
        redemption
        |> Map.put("started_at", DateTime.to_iso8601(DateTime.add(recovery_now, -10, :minute)))
        |> put_in(["provider_replay", "next_action_at"], DateTime.to_iso8601(recovery_now))

      update_redemption!(persisted, due_redemption)

      FakeUpstream.set_mode(fake, {
        :path_json,
        %{
          "/backend-api/wham/rate-limit-reset-credits" =>
            {200,
             %{
               "credits" => [
                 %{"id" => "credit_other", "status" => "available"},
                 %{"id" => "credit_original", "status" => "available"}
               ],
               "available_count" => 2
             }},
          "/backend-api/wham/rate-limit-reset-credits/consume" =>
            {200, %{"code" => "already_redeemed"}},
          "/backend-api/wham/usage" => {200, usage_payload(0)}
        }
      })

      assert {:ok, %{status: :succeeded, applied?: true, code: "already_redeemed"}} =
               SavedResetRedemption.resume_stale_consuming(
                 assignment,
                 identity.id,
                 redemption["attempt_id"],
                 redemption["generation"],
                 now: recovery_now,
                 receive_timeout: 1_000
               )

      requests = FakeUpstream.requests(fake)
      replay_consume = Enum.at(requests, 3)
      assert replay_consume.method == "POST"
      assert replay_consume.json["credit_id"] == "credit_original"
      assert replay_consume.json["redeem_request_id"] == first_consume.json["redeem_request_id"]

      settled = Repo.reload!(identity).metadata
      assert settled["saved_reset_redemption"]["provider_replay"]["provider_dispatches"] == 2
      refute Map.has_key?(settled, "saved_reset_redemption_target")
    end

    test "stale recovery honors persisted replay due time without provider I/O" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => :close_before_headers
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               SavedResetRedemption.redeem(assignment)

      assert length(FakeUpstream.requests(fake)) == 1

      recovery_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      next_action_at = DateTime.add(recovery_now, 90, :second)
      persisted = Repo.reload!(identity)
      redemption = persisted.metadata["saved_reset_redemption"]

      not_due_redemption =
        redemption
        |> Map.put("started_at", DateTime.to_iso8601(DateTime.add(recovery_now, -10, :minute)))
        |> put_in(["provider_replay", "next_action_at"], DateTime.to_iso8601(next_action_at))

      update_redemption!(persisted, not_due_redemption)

      assert {:snooze, 90} =
               SavedResetRedemption.resume_stale_consuming(
                 assignment,
                 identity.id,
                 redemption["attempt_id"],
                 redemption["generation"],
                 now: recovery_now,
                 receive_timeout: 0
               )

      assert length(FakeUpstream.requests(fake)) == 1

      assert Repo.reload!(identity).metadata["saved_reset_redemption"]["provider_replay"][
               "provider_dispatches"
             ] == 1
    end

    test "stale ChatGPT recovery uses exact redeemed and redeeming list evidence without a POST" do
      for {status, expected_result} <- [
            {"redeemed", :settled},
            {"redeeming", :deferred}
          ] do
        fixture = ambiguous_chatgpt_recovery_fixture!()
        recovery_now = DateTime.add(fixture.last_provider_dispatched_at, 60, :second)
        fixture = make_recovery_due!(fixture, recovery_now)

        FakeUpstream.set_mode(fixture.fake, {
          :path_json,
          %{
            "/backend-api/wham/rate-limit-reset-credits" =>
              {200,
               %{
                 "credits" => [
                   %{
                     "id" => fixture.credit_id,
                     "status" => status,
                     "redeemed_at" => DateTime.to_iso8601(recovery_now)
                   }
                 ]
               }}
          }
        })

        result = resume_recovery(fixture, recovery_now)

        case expected_result do
          :settled ->
            assert {:ok, %{status: :succeeded, applied?: true, code: "target_redeemed"}} = result

            metadata = Repo.reload!(fixture.identity).metadata
            refute Map.has_key?(metadata, "saved_reset_redemption_target")

          :deferred ->
            assert {:snooze, 60} = result

            redemption = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
            assert redemption["status"] == "redeeming"
            assert redemption["phase"] == "consuming"
            assert redemption["provider_replay"]["last_code"] == "target_redeeming"
        end

        assert provider_credit_consume_count(fixture.fake) == 1
        assert List.last(FakeUpstream.requests(fixture.fake)).method == "GET"
      end
    end

    test "stale ChatGPT recovery does not POST when the fresh list fails or is malformed" do
      for response <- [
            {503, %{"error" => "synthetic list failure"}},
            {200, %{"credits" => [%{"id" => "malformed_credit", "status" => "unknown"}]}}
          ] do
        fixture = ambiguous_chatgpt_recovery_fixture!()
        recovery_now = DateTime.add(fixture.last_provider_dispatched_at, 60, :second)
        fixture = make_recovery_due!(fixture, recovery_now)

        FakeUpstream.set_mode(fixture.fake, {
          :path_json,
          %{"/backend-api/wham/rate-limit-reset-credits" => response}
        })

        assert {:snooze, 60} = resume_recovery(fixture, recovery_now)
        assert provider_credit_consume_count(fixture.fake) == 1

        redemption = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
        assert redemption["provider_replay"]["provider_dispatches"] == 1
        assert redemption["provider_replay"]["last_code"] == "list_failed"
      end
    end

    test "an available pinned ChatGPT target remains ambiguous after the 30 minute floor" do
      fixture = ambiguous_chatgpt_recovery_fixture!()
      recovery_now = DateTime.add(fixture.last_provider_dispatched_at, 31, :minute)

      fixture =
        make_recovery_due!(fixture, recovery_now,
          started_at: DateTime.add(recovery_now, -40, :minute)
        )

      FakeUpstream.set_mode(fixture.fake, {
        :path_json,
        %{
          "/backend-api/wham/rate-limit-reset-credits" =>
            {200,
             %{
               "credits" => [
                 %{"id" => fixture.credit_id, "status" => "available"},
                 %{"id" => "credit_retarget_forbidden", "status" => "available"}
               ]
             }},
          "/backend-api/wham/rate-limit-reset-credits/consume" =>
            {503, %{"code" => "provider_failed"}}
        }
      })

      result = resume_recovery(fixture, recovery_now)
      assert {:snooze, 300} = result

      requests = FakeUpstream.requests(fixture.fake)
      replay_consume = List.last(requests)
      assert replay_consume.method == "POST"
      assert replay_consume.json["credit_id"] == fixture.credit_id
      assert replay_consume.json["redeem_request_id"] == fixture.redeem_request_id

      redemption = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
      assert redemption["status"] == "redeeming"
      assert redemption["phase"] == "consuming"
      assert redemption["result"] == nil
      assert redemption["provider_replay"]["provider_dispatches"] == 2
    end

    test "stale Codex recovery settles only from fresh usable quota evidence" do
      usable_fixture = ambiguous_codex_recovery_fixture!()
      usable_now = DateTime.add(usable_fixture.last_provider_dispatched_at, 60, :second)
      usable_fixture = make_recovery_due!(usable_fixture, usable_now)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(usable_fixture.identity, [
                 weekly_quota_attrs(Decimal.new("10"),
                   observed_at: usable_now,
                   last_sync_at: usable_now,
                   reset_at: DateTime.add(usable_now, 2, :hour)
                 )
               ])

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               resume_recovery(usable_fixture, usable_now)

      assert FakeUpstream.count(usable_fixture.fake) == 1

      exhausted_fixture = ambiguous_codex_recovery_fixture!()
      exhausted_now = DateTime.add(exhausted_fixture.last_provider_dispatched_at, 60, :second)
      exhausted_fixture = make_recovery_due!(exhausted_fixture, exhausted_now)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(exhausted_fixture.identity, [
                 weekly_quota_attrs(Decimal.new("100"),
                   observed_at: exhausted_now,
                   last_sync_at: exhausted_now,
                   reset_at: DateTime.add(exhausted_now, 2, :hour)
                 )
               ])

      FakeUpstream.set_mode(exhausted_fixture.fake, :close_before_headers)

      assert {:snooze, 300} = resume_recovery(exhausted_fixture, exhausted_now)
      assert FakeUpstream.count(exhausted_fixture.fake) == 2

      redemption = Repo.reload!(exhausted_fixture.identity).metadata["saved_reset_redemption"]
      assert redemption["status"] == "redeeming"
      assert redemption["provider_replay"]["provider_dispatches"] == 2
    end

    test "stale recovery enforces every persisted replay delay at the exact boundary" do
      for {provider_dispatches, delay_seconds, expected_snooze} <- [
            {1, 60, 5 * 60},
            {2, 5 * 60, 15 * 60},
            {3, 15 * 60, 60 * 60},
            {4, 60 * 60, 3 * 60 * 60},
            {5, 3 * 60 * 60, 30 * 60}
          ] do
        fixture = ambiguous_codex_recovery_fixture!()
        due_at = DateTime.add(fixture.last_provider_dispatched_at, delay_seconds, :second)

        fixture =
          make_recovery_due!(fixture, due_at,
            provider_dispatches: provider_dispatches,
            last_provider_dispatched_at: fixture.last_provider_dispatched_at,
            next_action_at: nil,
            started_at: DateTime.add(fixture.last_provider_dispatched_at, -10, :minute)
          )

        assert {:snooze, 1} = resume_recovery(fixture, DateTime.add(due_at, -1, :second))
        assert FakeUpstream.count(fixture.fake) == 1

        FakeUpstream.set_mode(fixture.fake, :close_before_headers)
        assert {:snooze, ^expected_snooze} = resume_recovery(fixture, due_at)
        assert FakeUpstream.count(fixture.fake) == 2

        replay =
          Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]["provider_replay"]

        assert replay["provider_dispatches"] == provider_dispatches + 1

        if provider_dispatches == 5 do
          assert replay["mode"] == "observe_only"
          assert replay["last_code"] == "write_budget_exhausted"

          assert replay["next_action_at"] ==
                   due_at |> DateTime.add(30, :minute) |> DateTime.to_iso8601()
        else
          assert replay["mode"] == "replay"
        end
      end
    end

    test "stale recovery never reserves beyond six writes or at the exact six hour cutoff" do
      budget_fixture = ambiguous_codex_recovery_fixture!()
      budget_now = DateTime.add(budget_fixture.last_provider_dispatched_at, 5, :minute)

      budget_fixture =
        make_recovery_due!(budget_fixture, budget_now,
          provider_dispatches: 6,
          last_provider_dispatched_at: budget_fixture.last_provider_dispatched_at,
          next_action_at: budget_now,
          started_at: DateTime.add(budget_now, -5, :hour)
        )

      assert {:snooze, 1_500} = resume_recovery(budget_fixture, budget_now)

      assert FakeUpstream.count(budget_fixture.fake) == 1

      budget_replay =
        Repo.reload!(budget_fixture.identity).metadata["saved_reset_redemption"][
          "provider_replay"
        ]

      assert budget_replay["mode"] == "observe_only"
      assert budget_replay["last_code"] == "write_budget_exhausted"
      assert is_binary(budget_replay["replay_exhausted_at"])
      assert is_binary(budget_replay["unresolved_since"])

      assert budget_replay["next_action_at"] ==
               budget_fixture.last_provider_dispatched_at
               |> DateTime.add(30, :minute)
               |> DateTime.to_iso8601()

      cutoff_fixture = ambiguous_codex_recovery_fixture!()
      cutoff_now = DateTime.add(cutoff_fixture.last_provider_dispatched_at, 60, :second)

      cutoff_fixture =
        make_recovery_due!(cutoff_fixture, cutoff_now,
          started_at: DateTime.add(cutoff_now, -6, :hour)
        )

      assert {:snooze, 1_740} = resume_recovery(cutoff_fixture, cutoff_now)

      assert FakeUpstream.count(cutoff_fixture.fake) == 1
    end

    test "observe-only zero-dispatch attempts settle not applied without provider I/O or a new floor" do
      fixture = ambiguous_chatgpt_recovery_fixture!()
      now = DateTime.add(fixture.last_provider_dispatched_at, 6, :hour)
      carried_at = DateTime.add(now, -5, :minute) |> DateTime.to_iso8601()
      persisted = Repo.reload!(fixture.identity)
      redemption = persisted.metadata["saved_reset_redemption"]

      replay =
        redemption["provider_replay"]
        |> Map.put("provider_dispatches", 0)
        |> Map.delete("last_provider_dispatched_at")
        |> Map.put("next_action_at", DateTime.to_iso8601(now))

      redemption =
        redemption
        |> Map.put("started_at", now |> DateTime.add(-6, :hour) |> DateTime.to_iso8601())
        |> Map.put("last_applied_consume_at", carried_at)
        |> Map.put("provider_replay", replay)

      metadata =
        persisted.metadata
        |> Map.put("saved_reset_redemption", redemption)

      update_identity!(persisted, %{metadata: metadata})
      request_count = FakeUpstream.count(fixture.fake)

      assert {:ok, %{status: :noop, code: "consume_not_applied"}} =
               resume_recovery(fixture, now)

      assert FakeUpstream.count(fixture.fake) == request_count

      settled = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
      assert settled["phase"] == "consume_not_applied"
      assert settled["result"]["applied"] == false
      assert settled["last_applied_consume_at"] == carried_at
      refute Map.has_key?(settled, "consumed_at")
      refute Map.has_key?(settled, "deadline_at")

      refute Map.has_key?(
               Repo.reload!(fixture.identity).metadata,
               "saved_reset_redemption_target"
             )
    end

    test "observe-only ChatGPT probes settle only exact redeemed and never POST" do
      for status <- ["redeemed", "available", "redeeming"] do
        fixture = ambiguous_chatgpt_recovery_fixture!()
        now = DateTime.add(fixture.last_provider_dispatched_at, 31, :minute)

        fixture =
          make_recovery_due!(fixture, now,
            provider_dispatches: 6,
            started_at: DateTime.add(now, -5, :hour)
          )

        FakeUpstream.set_mode(fixture.fake, {
          :path_json,
          %{
            "/backend-api/wham/rate-limit-reset-credits" =>
              {200,
               %{
                 "credits" => [
                   %{
                     "id" => fixture.credit_id,
                     "status" => status,
                     "redeemed_at" => DateTime.to_iso8601(now)
                   }
                 ]
               }}
          }
        })

        result = resume_recovery(fixture, now)

        if status == "redeemed" do
          assert {:ok, %{status: :succeeded, applied?: true, code: "target_redeemed"}} =
                   result
        else
          assert {:snooze, 21_600} = result
          persisted = Repo.reload!(fixture.identity).metadata
          assert is_binary(persisted["saved_reset_redemption_target"])
          assert persisted["saved_reset_redemption"]["phase"] == "consuming"
        end

        assert provider_credit_consume_count(fixture.fake) == 1
        assert List.last(FakeUpstream.requests(fixture.fake)).method == "GET"
      end
    end

    test "observe-only Codex ambiguity probes at six-hour cadence without another POST" do
      fixture = ambiguous_codex_recovery_fixture!()
      now = DateTime.add(fixture.last_provider_dispatched_at, 31, :minute)

      fixture =
        make_recovery_due!(fixture, now,
          provider_dispatches: 6,
          started_at: DateTime.add(now, -5, :hour)
        )

      assert {:snooze, 21_600} = resume_recovery(fixture, now)
      assert FakeUpstream.count(fixture.fake) == 1

      replay =
        Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]["provider_replay"]

      assert replay["mode"] == "observe_only"
      assert replay["last_code"] == "quota_unresolved"
      assert replay["next_action_at"] == now |> DateTime.add(6, :hour) |> DateTime.to_iso8601()
    end

    test "observe-only starts exactly at the provider staleness floor" do
      fixture = ambiguous_codex_recovery_fixture!()
      floor_at = DateTime.add(fixture.last_provider_dispatched_at, 30, :minute)

      fixture =
        make_recovery_due!(fixture, floor_at,
          provider_dispatches: 6,
          started_at: DateTime.add(floor_at, -5, :hour)
        )

      assert {:snooze, 1} = resume_recovery(fixture, DateTime.add(floor_at, -1, :second))
      assert FakeUpstream.count(fixture.fake) == 1

      assert {:snooze, 21_600} = resume_recovery(fixture, floor_at)
      assert FakeUpstream.count(fixture.fake) == 1

      replay =
        Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]["provider_replay"]

      assert replay["mode"] == "observe_only"
      assert replay["last_code"] == "quota_unresolved"

      assert replay["next_action_at"] ==
               floor_at |> DateTime.add(6, :hour) |> DateTime.to_iso8601()
    end

    test "old observe-only ChatGPT failures stay consuming and retain any private target" do
      for scenario <- [
            :missing_row,
            :unknown_status,
            :list_failure,
            :target_invalid,
            :target_missing,
            :scope_changed
          ] do
        fixture = ambiguous_chatgpt_recovery_fixture!()
        now = DateTime.add(fixture.last_provider_dispatched_at, 2, :day)

        fixture =
          make_recovery_due!(fixture, now,
            provider_dispatches: 6,
            started_at: DateTime.add(now, -2, :day)
          )

        persisted = Repo.reload!(fixture.identity)
        original_target = persisted.metadata["saved_reset_redemption_target"]

        {metadata, account_id, list_response} =
          case scenario do
            :missing_row ->
              {persisted.metadata, persisted.chatgpt_account_id, {200, %{"credits" => []}}}

            :unknown_status ->
              {persisted.metadata, persisted.chatgpt_account_id,
               {200,
                %{
                  "credits" => [
                    %{"id" => fixture.credit_id, "status" => "future_status"}
                  ]
                }}}

            :list_failure ->
              {persisted.metadata, persisted.chatgpt_account_id,
               {503, %{"error" => "synthetic list failure"}}}

            :target_invalid ->
              {Map.put(persisted.metadata, "saved_reset_redemption_target", "tampered"),
               persisted.chatgpt_account_id, nil}

            :target_missing ->
              {Map.delete(persisted.metadata, "saved_reset_redemption_target"),
               persisted.chatgpt_account_id, nil}

            :scope_changed ->
              {persisted.metadata, "acct_changed_observe_only_scope", nil}
          end

        update_identity!(persisted, %{metadata: metadata, chatgpt_account_id: account_id})

        if list_response do
          FakeUpstream.set_mode(fixture.fake, {
            :path_json,
            %{"/backend-api/wham/rate-limit-reset-credits" => list_response}
          })
        end

        request_count = FakeUpstream.count(fixture.fake)
        assert {:snooze, 21_600} = resume_recovery(fixture, now)

        updated_metadata = Repo.reload!(fixture.identity).metadata
        updated = updated_metadata["saved_reset_redemption"]
        assert updated["status"] == "redeeming"
        assert updated["phase"] == "consuming"

        assert updated["provider_replay"]["next_action_at"] ==
                 now |> DateTime.add(6, :hour) |> DateTime.to_iso8601()

        case scenario do
          scenario
          when scenario in [:missing_row, :unknown_status, :list_failure, :scope_changed] ->
            assert updated_metadata["saved_reset_redemption_target"] == original_target

          :target_invalid ->
            assert updated_metadata["saved_reset_redemption_target"] == "tampered"

          :target_missing ->
            refute Map.has_key?(updated_metadata, "saved_reset_redemption_target")
        end

        expected_requests =
          if scenario in [:missing_row, :unknown_status, :list_failure],
            do: request_count + 1,
            else: request_count

        assert FakeUpstream.count(fixture.fake) == expected_requests
        assert provider_credit_consume_count(fixture.fake) == 1
      end
    end

    @tag :saved_reset_observe_only_replica_race
    test "two observe-only replicas cannot reopen a settled attempt with a late result" do
      parent = self()
      first_release = make_ref()
      second_release = make_ref()
      {:ok, fake} = recovery_race_fake()
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_chatgpt_recovery_fixture!(fake)
      on_exit(fn -> cleanup_committed_recovery_fixture!(fixture) end)
      now = DateTime.add(fixture.now, 31, :minute)

      run_unboxed(fn ->
        identity = Repo.get!(UpstreamIdentity, fixture.identity_id)
        redemption = identity.metadata["saved_reset_redemption"]

        replay =
          redemption["provider_replay"]
          |> Map.put("provider_dispatches", 6)
          |> Map.put("mode", "observe_only")
          |> Map.put("next_action_at", DateTime.to_iso8601(now))

        update_redemption!(
          identity,
          redemption
          |> Map.put("started_at", now |> DateTime.add(-5, :hour) |> DateTime.to_iso8601())
          |> Map.put("provider_replay", replay)
        )
      end)

      fixture = %{fixture | now: now}

      FakeUpstream.set_mode(fake, {
        :sequence,
        [
          FakeUpstream.barrier_json_response(
            %{
              "credits" => [
                %{
                  "id" => fixture.credit_id,
                  "status" => "redeemed",
                  "redeemed_at" => DateTime.to_iso8601(now)
                }
              ]
            },
            notify: parent,
            release_ref: first_release
          ),
          FakeUpstream.barrier_json_response(
            %{
              "credits" => [
                %{
                  "id" => fixture.credit_id,
                  "status" => "redeemed",
                  "redeemed_at" => DateTime.to_iso8601(now)
                }
              ]
            },
            notify: parent,
            release_ref: second_release
          )
        ]
      })

      tasks =
        for role <- [:first, :second] do
          start_recovery_replica_task(parent, role, fixture)
        end

      assert_receive {:recovery_replica_ready, :first}, 5_000
      assert_receive {:recovery_replica_ready, :second}, 5_000
      Enum.each(tasks, &send(&1.pid, :start_recovery))

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, first_pid, ^first_release},
                     5_000

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, second_pid,
                      ^second_release},
                     5_000

      send(first_pid, {:fake_upstream_release_timeout, first_release})
      send(second_pid, {:fake_upstream_release_timeout, second_release})

      results = Task.await_many(tasks, 15_000)
      assert Enum.count(results, &match?({_, {:ok, %{status: :succeeded}}}, &1)) == 1

      persisted =
        run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end).metadata

      assert persisted["saved_reset_redemption"]["result"]["applied"] == true

      assert persisted["saved_reset_redemption"]["phase"] in [
               "confirmed_by_quota",
               "consumed_pending_probe"
             ]

      refute Map.has_key?(persisted, "saved_reset_redemption_target")
      assert provider_credit_consume_count(fake) == 1
    end

    @tag :saved_reset_original_finalizer_race
    test "a late original finalizer cannot overwrite a terminal recovery result" do
      parent = self()
      consume_release = make_ref()
      {:ok, fake} = recovery_race_fake()
      on_exit(fn -> FakeUpstream.stop(fake) end)

      credit_id = "credit_original_race_#{System.unique_integer([:positive, :monotonic])}"
      redeemed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      FakeUpstream.set_mode(fake, {
        :sequence,
        [
          {:json, 200, %{"credits" => [%{"id" => credit_id, "status" => "available"}]}},
          FakeUpstream.barrier_json_response(%{"code" => "no_credit"},
            notify: parent,
            release_ref: consume_release
          ),
          {:json, 200,
           %{
             "credits" => [
               %{
                 "id" => credit_id,
                 "status" => "redeemed",
                 "redeemed_at" => DateTime.to_iso8601(redeemed_at)
               }
             ]
           }}
        ]
      })

      fixture =
        run_unboxed(fn ->
          %{identity: identity, assignment: assignment} =
            assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

          %{
            assignment_id: assignment.id,
            identity_id: identity.id,
            pool_id: assignment.pool_id
          }
        end)

      on_exit(fn -> cleanup_committed_recovery_fixture!(fixture) end)

      original_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.checkout(fn -> SavedResetRedemption.redeem(fixture.assignment_id) end)
          end)
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, consume_pid,
                      ^consume_release},
                     5_000

      reserved =
        run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end).metadata[
          "saved_reset_redemption"
        ]

      assert reserved["provider_replay"]["provider_dispatches"] == 1

      recovery_fixture =
        fixture
        |> Map.put(:attempt_id, reserved["attempt_id"])
        |> Map.put(:generation, reserved["generation"])
        |> Map.put(:now, DateTime.add(DateTime.utc_now(), 31, :minute))

      recovery_task = start_recovery_replica_task(parent, :recovery, recovery_fixture)
      assert_receive {:recovery_replica_ready, :recovery}, 5_000
      send(recovery_task.pid, :start_recovery)

      assert {:recovery, {:ok, %{status: :succeeded, applied?: true}}} =
               Task.await(recovery_task, 15_000)

      settled =
        run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end).metadata

      assert settled["saved_reset_redemption"]["result"]["applied"] == true

      assert settled["saved_reset_redemption"]["phase"] in [
               "confirmed_by_quota",
               "consumed_pending_probe"
             ]

      send(consume_pid, {:fake_upstream_release_timeout, consume_release})

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               Task.await(original_task, 15_000)

      persisted =
        run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end).metadata

      assert persisted == settled
      assert provider_credit_consume_count(fake) == 1
    end

    test "invalid ChatGPT recovery targets and changed scope remain provider I/O free" do
      for mutation <- [:tampered_target, :missing_target, :scope_changed] do
        fixture = ambiguous_chatgpt_recovery_fixture!()
        recovery_now = DateTime.add(fixture.last_provider_dispatched_at, 60, :second)
        fixture = make_recovery_due!(fixture, recovery_now)
        persisted = Repo.reload!(fixture.identity)

        metadata =
          case mutation do
            :tampered_target ->
              Map.put(persisted.metadata, "saved_reset_redemption_target", "tampered")

            :missing_target ->
              Map.delete(persisted.metadata, "saved_reset_redemption_target")

            :scope_changed ->
              persisted.metadata
          end

        attrs =
          if mutation == :scope_changed,
            do: %{metadata: metadata, chatgpt_account_id: "acct_changed_scope"},
            else: %{metadata: metadata}

        update_identity!(persisted, attrs)

        assert {:ok, %{status: :noop, applied?: false, code: code}} =
                 resume_recovery(fixture, recovery_now)

        assert code in ["recovery_target_invalid", "scope_changed"]
        assert FakeUpstream.count(fixture.fake) == 2
      end
    end

    test "markerless and marked legacy recovery normalize to the same observe-only result" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      marker = %{"version" => 1, "state" => "unresolved"}

      for legacy_recovery <- [nil, marker] do
        {:ok, fake} = FakeUpstream.start_link(:close_before_headers)
        on_exit(fn -> FakeUpstream.stop(fake) end)

        redemption = %{
          "status" => "redeeming",
          "phase" => "consuming",
          "attempt_id" => Ecto.UUID.generate(),
          "generation" => 3,
          "trigger_kind" => "admin_manual",
          "started_at" => DateTime.to_iso8601(DateTime.add(now, -10, :minute)),
          "finished_at" => nil,
          "result" => nil
        }

        redemption =
          if legacy_recovery,
            do: Map.put(redemption, "legacy_recovery", legacy_recovery),
            else: redemption

        %{identity: identity, assignment: assignment} =
          assignment_with_fake(fake, "/api/codex/usage", "codex_api", redemption: redemption)

        assert {:snooze, 21_600} =
                 SavedResetRedemption.resume_stale_consuming(
                   assignment,
                   identity.id,
                   redemption["attempt_id"],
                   redemption["generation"],
                   now: now,
                   receive_timeout: 0
                 )

        persisted = Repo.reload!(identity).metadata["saved_reset_redemption"]
        assert persisted["legacy_recovery"] == marker

        assert persisted["legacy_recovery_last_code"] == "legacy_unresolved"
        assert is_binary(persisted["legacy_recovery_last_observed_at"])

        assert persisted["legacy_recovery_next_action_at"] ==
                 now |> DateTime.add(6, :hour) |> DateTime.to_iso8601()

        assert Map.drop(persisted, [
                 "legacy_recovery",
                 "legacy_recovery_last_code",
                 "legacy_recovery_last_observed_at",
                 "legacy_recovery_next_action_at"
               ]) == Map.drop(redemption, ["legacy_recovery"])

        assert FakeUpstream.requests(fake) == []
      end
    end

    test "a present malformed replay contract remains fail-closed without provider I/O" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      redemption = %{
        "status" => "redeeming",
        "phase" => "consuming",
        "attempt_id" => Ecto.UUID.generate(),
        "generation" => 3,
        "trigger_kind" => "admin_manual",
        "started_at" => DateTime.to_iso8601(DateTime.add(now, -10, :minute)),
        "finished_at" => nil,
        "result" => nil,
        "provider_replay" => "invalid"
      }

      {:ok, fake} = FakeUpstream.start_link(:close_before_headers)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api", redemption: redemption)

      assert {:ok, %{status: :noop, applied?: false, code: "scope_changed"}} =
               SavedResetRedemption.resume_stale_consuming(
                 assignment,
                 identity.id,
                 redemption["attempt_id"],
                 redemption["generation"],
                 now: now,
                 receive_timeout: 0
               )

      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == redemption
      assert FakeUpstream.requests(fake) == []
    end

    test "a recovery reservation re-checks the six-hour cutoff after the provider list" do
      fixture = ambiguous_chatgpt_recovery_fixture!()
      recovery_now = DateTime.add(fixture.last_provider_dispatched_at, 60, :second)
      started_at = DateTime.add(recovery_now, -(6 * 60 * 60 - 30), :second)
      fixture = make_recovery_due!(fixture, recovery_now, started_at: started_at)
      before_metadata = Repo.reload!(fixture.identity).metadata

      assert {:ok, %{status: :noop, applied?: false, code: "write_budget_exhausted"}} =
               SavedResetRedemption.resume_stale_consuming(
                 fixture.assignment,
                 fixture.identity.id,
                 fixture.attempt_id,
                 fixture.generation,
                 now: recovery_now,
                 receive_timeout: 1_000,
                 clock: fn -> DateTime.add(recovery_now, 60, :second) end
               )

      assert Repo.reload!(fixture.identity).metadata == before_metadata
      assert provider_credit_consume_count(fixture.fake) == 1
    end

    @tag :saved_reset_recovery_replica_race
    test "two recovery replicas reserve and POST at most one additional dispatch" do
      parent = self()
      first_release = make_ref()
      second_release = make_ref()
      {:ok, fake} = recovery_race_fake()
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_chatgpt_recovery_fixture!(fake)
      on_exit(fn -> cleanup_committed_recovery_fixture!(fixture) end)

      FakeUpstream.set_mode(fake, {
        :sequence,
        [
          FakeUpstream.barrier_json_response(
            %{"credits" => [%{"id" => fixture.credit_id, "status" => "available"}]},
            notify: parent,
            release_ref: first_release
          ),
          FakeUpstream.barrier_json_response(
            %{"credits" => [%{"id" => fixture.credit_id, "status" => "available"}]},
            notify: parent,
            release_ref: second_release
          ),
          {:json, 200, %{"code" => "reset"}},
          {:json, 200, usage_payload(0)}
        ]
      })

      tasks =
        for role <- [:first, :second] do
          start_recovery_replica_task(parent, role, fixture)
        end

      assert_receive {:recovery_replica_ready, :first}, 5_000
      assert_receive {:recovery_replica_ready, :second}, 5_000
      Enum.each(tasks, &send(&1.pid, :start_recovery))

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, first_pid, ^first_release},
                     5_000

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, second_pid,
                      ^second_release},
                     5_000

      send(first_pid, {:fake_upstream_release_timeout, first_release})
      send(second_pid, {:fake_upstream_release_timeout, second_release})

      results = Task.await_many(tasks, 15_000)
      assert Enum.count(results, &match?({_, {:ok, %{applied?: true}}}, &1)) == 1
      assert provider_credit_consume_count(fake) == 2

      persisted =
        run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end).metadata[
          "saved_reset_redemption"
        ]

      assert persisted["provider_replay"]["provider_dispatches"] == 2
    end

    @tag :saved_reset_recovery_dispatch_generation_race
    test "only the current dispatch reservation can finalize the attempt" do
      parent = self()
      first_release = make_ref()
      second_release = make_ref()
      {:ok, fake} = recovery_race_fake()
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_chatgpt_recovery_fixture!(fake)
      on_exit(fn -> cleanup_committed_recovery_fixture!(fixture) end)

      FakeUpstream.set_mode(fake, {
        :sequence,
        [
          {:json, 200, %{"credits" => [%{"id" => fixture.credit_id, "status" => "available"}]}},
          FakeUpstream.barrier_json_response(%{"code" => "reset"},
            notify: parent,
            release_ref: first_release
          ),
          {:json, 200, %{"credits" => [%{"id" => fixture.credit_id, "status" => "available"}]}},
          FakeUpstream.barrier_json_response(%{"code" => "reset"},
            notify: parent,
            release_ref: second_release
          ),
          {:json, 200, usage_payload(0)},
          {:json, 200, usage_payload(0)}
        ]
      })

      stale_task = start_recovery_replica_task(parent, :stale, fixture)
      assert_receive {:recovery_replica_ready, :stale}, 5_000
      send(stale_task.pid, :start_recovery)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, stale_pid, ^first_release},
                     5_000

      current_fixture = %{fixture | now: DateTime.add(fixture.now, 6, :minute)}
      current_task = start_recovery_replica_task(parent, :current, current_fixture)
      assert_receive {:recovery_replica_ready, :current}, 5_000
      send(current_task.pid, :start_recovery)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, current_pid,
                      ^second_release},
                     5_000

      send(stale_pid, {:fake_upstream_release_timeout, first_release})

      assert {:stale, {:error, :saved_reset_consume_outcome_ambiguous}} =
               Task.await(stale_task, 15_000)

      active =
        run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end).metadata[
          "saved_reset_redemption"
        ]

      assert active["status"] == "redeeming"
      assert active["phase"] == "consuming"
      assert active["result"] == nil
      assert active["provider_replay"]["provider_dispatches"] == 3

      send(current_pid, {:fake_upstream_release_timeout, second_release})

      assert {:current, {:ok, %{status: :succeeded, applied?: true}}} =
               Task.await(current_task, 15_000)

      persisted =
        run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end).metadata[
          "saved_reset_redemption"
        ]

      assert persisted["result"]["applied"] == true
      assert persisted["provider_replay"]["provider_dispatches"] == 3

      # Fixture dispatch 1 plus exactly one POST per live reservation.
      assert provider_credit_consume_count(fake) == 3
    end

    test "a finalizer persistence failure after a reserved ChatGPT POST stays ambiguous" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [%{"id" => "credit_persistence", "status" => "available"}],
                  "available_count" => 1
                }},
             "/backend-api/wham/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/backend-api/wham/usage" => {200, usage_payload(0)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      install_saved_reset_finalization_failure_trigger!(identity.id)

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               SavedResetRedemption.redeem(assignment)

      metadata = Repo.reload!(identity).metadata
      redemption = metadata["saved_reset_redemption"]

      assert redemption["status"] == "redeeming"
      assert redemption["phase"] == "consuming"
      assert redemption["result"] == nil
      assert redemption["finished_at"] == nil
      assert redemption["provider_replay"]["provider_dispatches"] == 1
      assert redemption["provider_replay"]["last_code"] == "persistence_failed"
      assert is_binary(metadata["saved_reset_redemption_target"])

      assert Enum.map(FakeUpstream.requests(fake), &{&1.method, &1.path}) == [
               {"GET", "/backend-api/wham/rate-limit-reset-credits"},
               {"POST", "/backend-api/wham/rate-limit-reset-credits/consume"},
               {"GET", "/backend-api/wham/usage"}
             ]
    end

    test "treats every non-definitive response after a reserved POST as ambiguous" do
      scenarios = [
        {:empty_object, {:json, 200, %{}}},
        {:missing_code, {:json, 200, %{"credit" => %{}}}},
        {:non_string_code, {:json, 200, %{"code" => 1}}},
        {:unknown_code, {:json, 200, %{"code" => "provider_changed"}}},
        {:empty_204, {:raw_body, 204, "", []}},
        {:non_json, {:raw_body, 200, "not-json", [{"content-type", "text/plain"}]}},
        {:malformed_json, {:malformed_json, 200, "{"}},
        {:known_code_5xx, {:json, 503, %{"code" => "reset"}}},
        {:invalid_windows_reset, {:json, 200, %{"code" => "reset", "windows_reset" => "1"}}}
      ]

      for {scenario, response} <- scenarios do
        {:ok, fake} =
          FakeUpstream.start_link(
            {:path_json, %{"/api/codex/rate-limit-reset-credits/consume" => response}}
          )

        on_exit(fn -> FakeUpstream.stop(fake) end)

        %{identity: identity, assignment: assignment} =
          assignment_with_fake(fake, "/api/codex/usage", "codex_api")

        assert {:error, :saved_reset_consume_outcome_ambiguous} =
                 SavedResetRedemption.redeem(assignment),
               "scenario=#{scenario}"

        redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
        assert redemption["status"] == "redeeming", "scenario=#{scenario}"
        assert redemption["phase"] == "consuming", "scenario=#{scenario}"
        assert redemption["result"] == nil, "scenario=#{scenario}"

        assert redemption["provider_replay"]["provider_dispatches"] == 1,
               "scenario=#{scenario}"

        assert [%{method: "POST"}] = FakeUpstream.requests(fake), "scenario=#{scenario}"
        assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(assignment)
        assert length(FakeUpstream.requests(fake)) == 1, "scenario=#{scenario}"
      end
    end

    test "accepts only known 2xx object outcomes with valid optional fields" do
      for {code, expected_status, applied?} <- [
            {"already_redeemed", :succeeded, true},
            {"no_credit", :noop, false},
            {"nothing_to_reset", :noop, false}
          ] do
        {:ok, fake} =
          FakeUpstream.start_link(
            {:path_json,
             %{
               "/api/codex/rate-limit-reset-credits/consume" =>
                 {200, %{"code" => code, "windows_reset" => 1}},
               "/api/codex/usage" => {500, %{}}
             }}
          )

        on_exit(fn -> FakeUpstream.stop(fake) end)
        %{assignment: assignment} = assignment_with_fake(fake, "/api/codex/usage", "codex_api")

        assert {:ok, %{status: ^expected_status, applied?: ^applied?, code: ^code}} =
                 SavedResetRedemption.redeem(assignment)
      end
    end

    test "unsupported endpoint claims remain provider-I/O-free without replay metadata" do
      {:ok, fake} = codex_reset_fake(1)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/unsupported/usage", "codex_api")

      assert {:ok, %{status: :noop, code: "saved_reset_endpoint_unknown"}} =
               SavedResetRedemption.redeem(assignment)

      assert [] = FakeUpstream.requests(fake)
      redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
      refute Map.has_key?(redemption, "provider_replay")
      refute Map.has_key?(Repo.reload!(identity).metadata, "saved_reset_redemption_target")
    end

    @tag :saved_reset_redemption_cause
    test "gateway cause is derived from normalized trigger and survives claimed noops and ambiguity" do
      for {trigger, detail, provider_status, provider_code, expected_result} <- [
            {:blocked_weekly_exhaustion, "exhausted", 200, "nothing_to_reset",
             {:settled, :noop, "nothing_to_reset"}},
            {:threshold_pressure, "threshold", 502, "provider_rejected", :ambiguous}
          ] do
        parent = self()
        release_ref = make_ref()

        {:ok, fake} =
          FakeUpstream.start_link(
            FakeUpstream.barrier_json_response(%{"code" => provider_code},
              status: provider_status,
              notify: parent,
              release_ref: release_ref
            )
          )

        %{identity: identity, assignment: assignment} =
          assignment_with_fake(fake, "/api/codex/usage", "codex_api")

        policy =
          if trigger == :threshold_pressure,
            do: %{
              saved_reset_auto_redeem_trigger_mode: "threshold",
              saved_reset_auto_redeem_quota_threshold_percent: 95
            },
            else: %{}

        identity = enable_saved_reset_auto_redeem!(identity, policy)

        if trigger == :threshold_pressure do
          upsert_weekly_pressure_quota!(identity, Decimal.new("96"))
        else
          upsert_weekly_exhausted_quota!(identity)
        end

        context =
          assignment
          |> gateway_auto_context(identity, trigger)
          |> Map.put(:trigger_detail, "caller-controlled-provider-token")

        task =
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            SavedResetRedemption.redeem(assignment,
              trigger_kind: "gateway_auto",
              gateway_auto_context: context
            )
          end)

        assert_receive {:fake_upstream_timeout_barrier, :before_headers, fake_request_pid,
                        ^release_ref},
                       5_000

        claim = Repo.reload!(identity).metadata["saved_reset_redemption"]
        assert claim["status"] == "redeeming"
        assert claim["trigger_detail"] == detail
        refute Jason.encode!(claim) =~ "caller-controlled-provider-token"

        send(fake_request_pid, {:fake_upstream_release_timeout, release_ref})

        persisted =
          case expected_result do
            {:settled, status, result_code} ->
              assert {:ok, %{status: ^status, code: ^result_code}} = Task.await(task, 5_000)
              Repo.reload!(identity).metadata["saved_reset_redemption"]

            :ambiguous ->
              assert {:error, :saved_reset_consume_outcome_ambiguous} = Task.await(task, 5_000)
              redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
              assert redemption["status"] == "redeeming"
              assert redemption["phase"] == "consuming"
              assert redemption["result"] == nil
              redemption
          end

        assert persisted["trigger_detail"] == detail
        refute Jason.encode!(persisted) =~ "caller-controlled-provider-token"
      end
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
      assert body == %{"redeem_request_id" => redeem_request_id}
      assert is_binary(redeem_request_id)
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

    test "a stale phase-bearing consume cannot be reclaimed by a manual attempt" do
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

      before_redemption = identity.metadata["saved_reset_redemption"]

      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(assignment)
      assert [] = FakeUpstream.requests(fake)
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == before_redemption
    end

    test "an unconsumed persisted lifecycle record permits a fresh ordinary claim" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {500, %{"error" => "synthetic usage failure"}}
           }}
        )

      started_at =
        DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:microsecond)

      previous_attempt_id = Ecto.UUID.generate()

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: %{
            "status" => "failed",
            "phase" => "consume_not_applied",
            "attempt_id" => previous_attempt_id,
            "generation" => 5,
            "trigger_kind" => "admin_manual",
            "started_at" => DateTime.to_iso8601(started_at),
            "finished_at" => DateTime.to_iso8601(started_at),
            "result" => %{"code" => "transport_error", "applied" => false},
            "provider_replay" => %{"version" => 1, "provider_dispatches" => 0}
          }
        )

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      assert [consume_request, usage_request] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert usage_request.path == "/api/codex/usage"

      redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
      assert redemption["phase"] == "consumed_pending_probe"
      assert redemption["generation"] == 6
      refute redemption["attempt_id"] == previous_attempt_id
      assert redemption["result"]["code"] == "reset"
      assert redemption["result"]["applied"] == true
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

    test "gateway auto does not reclaim a stale phase-bearing consuming redemption" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      update_redemption!(
        identity,
        redemption_metadata("gateway_auto", DateTime.utc_now() |> DateTime.add(-5, :minute))
        |> Map.put("phase", "consuming")
      )

      before_redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]

      assert {:error, :redemption_in_progress} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == before_redemption
    end

    @tag :saved_reset_expiry_ownership
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

    test "gateway auto accepts narrowed trigger candidates within a wider normalized cohort" do
      {:ok, fake} = codex_reset_fake(0)
      {:ok, cohort_fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      %{identity: cohort_identity} =
        assignment_with_fake(cohort_fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)

      context =
        assignment
        |> gateway_auto_context(identity, :blocked_weekly_exhaustion)
        |> Map.put(:cohort_identity_ids, [
          cohort_identity.id,
          identity.id,
          cohort_identity.id
        ])

      assert {:ok, normalized_context} = AutoEligibility.normalize_context(context)
      assert normalized_context.candidate_identity_ids == [identity.id]

      assert normalized_context.cohort_identity_ids ==
               Enum.sort([identity.id, cohort_identity.id])

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [consume_request, _usage_request] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert [] = FakeUpstream.requests(cohort_fake)
    end

    test "gateway auto rejects missing, empty, and invalid cohorts before provider I/O" do
      for cohort_override <- [
            :missing,
            nil,
            [],
            "not-a-list",
            ["not-a-uuid"],
            [Ecto.UUID.generate(), "not-a-uuid"]
          ] do
        {:ok, fake} = codex_reset_fake(0)

        %{identity: identity, assignment: assignment} =
          assignment_with_fake(fake, "/api/codex/usage", "codex_api")

        identity = enable_saved_reset_auto_redeem!(identity)
        upsert_weekly_exhausted_quota!(identity)

        context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

        context =
          if cohort_override == :missing,
            do: Map.delete(context, :cohort_identity_ids),
            else: Map.put(context, :cohort_identity_ids, cohort_override)

        assert {:ok,
                %{
                  status: :noop,
                  applied?: false,
                  code: "gateway_auto_context_invalid"
                }} =
                 SavedResetRedemption.redeem(assignment,
                   trigger_kind: "gateway_auto",
                   gateway_auto_context: context
                 )

        assert [] = FakeUpstream.requests(fake)
      end
    end

    test "gateway auto rejects target, routeability, and cohort mismatches before provider I/O" do
      for relation <- [
            :target_outside_candidates,
            :target_outside_cohort,
            :candidate_outside_cohort,
            :candidate_outside_routable,
            :routable_outside_cohort
          ] do
        {:ok, fake} = codex_reset_fake(0)

        %{identity: identity, assignment: assignment} =
          assignment_with_fake(fake, "/api/codex/usage", "codex_api")

        identity = enable_saved_reset_auto_redeem!(identity)
        upsert_weekly_exhausted_quota!(identity)
        other_identity_id = Ecto.UUID.generate()

        context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

        context =
          case relation do
            :target_outside_candidates ->
              Map.put(context, :candidate_identity_ids, [other_identity_id])

            :target_outside_cohort ->
              Map.put(context, :cohort_identity_ids, [other_identity_id])

            :candidate_outside_cohort ->
              context
              |> Map.put(:candidate_identity_ids, [identity.id, other_identity_id])
              |> Map.put(:cohort_identity_ids, [identity.id])

            :candidate_outside_routable ->
              Map.put(context, :routable_identity_ids, [other_identity_id])

            :routable_outside_cohort ->
              Map.put(context, :routable_identity_ids, [identity.id, other_identity_id])
          end

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
      end
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

    @tag :saved_reset_expiry_ownership
    test "gateway auto rejects the retired expiration trigger before side effects" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)

      retired_trigger = String.to_atom("expiring" <> "_reset")
      context = gateway_auto_context(assignment, identity, retired_trigger)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_context_invalid"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(identity)
      refute Map.has_key?(persisted.metadata || %{}, "saved_reset_redemption")
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

    test "pure threshold decision compares the natural reset buffer at whole-second precision" do
      as_of = ~U[2026-07-29 12:00:00.900000Z]
      whole_second_as_of = DateTime.truncate(as_of, :second)
      policy = scheduled_burn_policy(%{trigger_mode: "threshold"})
      snapshot = scheduled_burn_snapshot(as_of, 2 * 60 * 60)

      for {reset_in_seconds, expected} <- [
            {60 * 60 - 1, {:not_ready, :natural_reset_buffer}},
            {60 * 60, :burn},
            {60 * 60 + 1, :burn}
          ] do
        reset_at =
          whole_second_as_of
          |> DateTime.add(reset_in_seconds, :second)
          |> DateTime.add(100_000, :microsecond)

        window = %{scheduled_burn_window(as_of, "95", reset_in_seconds) | reset_at: reset_at}
        result = AutoEligibility.scheduled_burn_condition([window], policy, snapshot, as_of)

        case expected do
          :burn -> assert {:burn, %{trigger_detail: "threshold"}} = result
          not_ready -> assert ^not_ready = result
        end
      end

      exhausted_window = %AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("100"),
        source: "codex_usage_api",
        source_precision: "observed",
        freshness_state: "fresh",
        observed_at: as_of
      }

      for {reset_in_seconds, expected?} <- [
            {60 * 60 - 1, false},
            {60 * 60, true},
            {60 * 60 + 1, true}
          ] do
        reset_at =
          whole_second_as_of
          |> DateTime.add(reset_in_seconds, :second)
          |> DateTime.add(100_000, :microsecond)

        assert AutoEligibility.blocked_weekly_exhaustion?(
                 [%{exhausted_window | reset_at: reset_at}],
                 policy,
                 as_of
               ) == expected?,
               "reset_in_seconds=#{reset_in_seconds}"
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

    @tag :saved_reset_redemption_cause
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

    test "preserves scheduled evidence on provider noop and ambiguous failure" do
      for {scenario, consume_response, expected_result} <- [
            {:noop, {200, %{"code" => "nothing_to_reset"}}, {:settled, :noop}},
            {:ambiguous, {502, %{"code" => "provider_rejected"}}, :ambiguous}
          ] do
        %{as_of: as_of, identity: identity, assignment: assignment} =
          scheduled_expiry_fixture(consume_response: consume_response)

        result =
          SavedResetRedemption.redeem_scheduled_expiry(
            assignment,
            identity.id,
            started_at: as_of
          )

        redemption =
          case expected_result do
            {:settled, expected_status} ->
              assert {:ok, %{status: ^expected_status, identity: persisted_identity}} = result,
                     "scenario=#{scenario}"

              persisted_identity.metadata["saved_reset_redemption"]

            :ambiguous ->
              assert {:error, :saved_reset_consume_outcome_ambiguous} = result,
                     "scenario=#{scenario}"

              redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
              assert redemption["status"] == "redeeming"
              assert redemption["phase"] == "consuming"
              assert redemption["result"] == nil
              redemption
          end

        assert Map.keys(Map.take(redemption, scheduled_decision_metadata_keys())) |> Enum.sort() ==
                 Enum.sort(scheduled_decision_metadata_keys())

        assert redemption["trigger_detail"] == "last_call"
        assert redemption["used_percent_at_decision"] == "25"
      end
    end

    @tag :saved_reset_redemption_cause
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

    test "scheduled weekly eligibility compares reset horizons at whole-second precision" do
      as_of = ~U[2026-07-29 12:00:00.900000Z]
      whole_second_as_of = DateTime.truncate(as_of, :second)
      max_reset_seconds = 7 * 24 * 60 * 60 + 60 * 60

      for {scenario, reset_at, expected} <- [
            {:same_second, DateTime.add(whole_second_as_of, 950_000, :microsecond), :unavailable},
            {:next_second,
             whole_second_as_of
             |> DateTime.add(1, :second)
             |> DateTime.add(100_000, :microsecond), {:eligible, 1}},
            {:maximum,
             whole_second_as_of
             |> DateTime.add(max_reset_seconds, :second)
             |> DateTime.add(100_000, :microsecond), {:eligible, 1}},
            {:beyond_maximum,
             whole_second_as_of
             |> DateTime.add(max_reset_seconds + 1, :second)
             |> DateTime.add(100_000, :microsecond), :unavailable}
          ] do
        %{identity: identity} = scheduled_expiry_fixture(as_of: as_of, quota?: false)

        attrs =
          scheduled_weekly_quota_attrs(as_of, Decimal.new("25"), reset_at: reset_at)

        assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
        windows = QuotaWindows.list_evidence(identity)

        case expected do
          {:eligible, expected_count} ->
            assert {:eligible, selected_windows} =
                     AutoEligibility.scheduled_weekly_eligibility(
                       windows,
                       SavedResets.snapshot(identity, as_of),
                       as_of
                     ),
                   "scenario=#{scenario}"

            assert length(selected_windows) == expected_count

          :unavailable ->
            assert :unavailable =
                     AutoEligibility.scheduled_weekly_eligibility(
                       windows,
                       SavedResets.snapshot(identity, as_of),
                       as_of
                     ),
                   "scenario=#{scenario}"
        end
      end
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

        await_after!(DateTime.add(expires_at, 1, :second))
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

    @tag :scheduled_expiry_stale_claim_residual
    test "phase-bearing consuming projects in progress instead of legacy staleness" do
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{identity: identity} =
        scheduled_expiry_fixture(
          as_of: as_of,
          redemption:
            redemption_metadata(
              "scheduled_expiry_rescue",
              DateTime.add(as_of, -5, :minute)
            )
            |> Map.put("phase", "consuming")
        )

      assert %{in_progress?: true, redemption_stale?: false} =
               SavedResets.snapshot(identity, as_of)
    end

    @tag :scheduled_expiry_stale_claim_residual
    test "phase-bearing consuming scheduled claim stays fail-closed and unchanged" do
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{fake: fake, identity: identity, assignment: assignment} =
        scheduled_expiry_fixture(
          as_of: as_of,
          redemption:
            redemption_metadata(
              "scheduled_expiry_rescue",
              DateTime.add(as_of, -5, :minute)
            )
            |> Map.put("phase", "consuming")
        )

      before_redemption = identity.metadata["saved_reset_redemption"]

      assert {:ok, %{status: :noop, applied?: false, code: "scheduled_expiry_redemption_stale"}} =
               SavedResetRedemption.redeem_scheduled_expiry(
                 assignment,
                 identity.id,
                 started_at: as_of
               )

      assert [] = FakeUpstream.requests(fake)
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == before_redemption
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
    @tag :saved_reset_cohort_lock_baseline
    test "manual and scheduled claims retain their single-target lock paths" do
      {:ok, manual_fake} = codex_reset_fake(0)
      {:ok, scheduled_fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(manual_fake) end)
      on_exit(fn -> FakeUpstream.stop(scheduled_fake) end)

      manual_fixture = committed_scheduled_expiry_race_fixture!(manual_fake)
      scheduled_fixture = committed_scheduled_expiry_race_fixture!(scheduled_fake)

      on_exit(fn -> cleanup_committed_scheduled_expiry_race_fixture!(manual_fixture) end)
      on_exit(fn -> cleanup_committed_scheduled_expiry_race_fixture!(scheduled_fixture) end)

      {manual_result, manual_locks} =
        run_unboxed(fn ->
          capture_claim_locks_until_identity_update!(fn ->
            SavedResetRedemption.redeem(List.first(manual_fixture.assignment_ids),
              started_at: manual_fixture.as_of
            )
          end)
        end)

      {scheduled_result, scheduled_locks} =
        run_unboxed(fn ->
          capture_claim_locks_until_identity_update!(fn ->
            SavedResetRedemption.redeem_scheduled_expiry(
              List.first(scheduled_fixture.assignment_ids),
              scheduled_fixture.identity_id,
              started_at: scheduled_fixture.as_of
            )
          end)
        end)

      assert {:ok, %{status: :succeeded, applied?: true}} = manual_result
      assert {:ok, %{status: :succeeded, applied?: true}} = scheduled_result

      assert Enum.map(manual_locks, & &1.source) == ["upstream_identities"]

      assert Enum.map(scheduled_locks, & &1.source) == [
               "upstream_identities",
               "pool_upstream_assignments"
             ]

      assert Enum.all?(manual_locks ++ scheduled_locks, &(not &1.cohort_query?))
    end

    test "manual and scheduled claims bypass a recent sibling fence" do
      {:ok, manual_fake} = codex_reset_fake(0)
      {:ok, scheduled_fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(manual_fake) end)
      on_exit(fn -> FakeUpstream.stop(scheduled_fake) end)

      manual_fixture = committed_gateway_auto_cohort_fixture!(manual_fake, :same_pool, 2)
      scheduled_fixture = committed_gateway_auto_cohort_fixture!(scheduled_fake, :same_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(manual_fixture) end)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(scheduled_fixture) end)

      Enum.each([manual_fixture, scheduled_fixture], fn fixture ->
        run_unboxed(fn ->
          fixture.identity_ids
          |> List.first()
          |> then(&Repo.get!(UpstreamIdentity, &1))
          |> update_redemption!(
            sibling_redemption(
              "confirmed_by_quota",
              DateTime.add(fixture.as_of, -5, :minute),
              true
            )
          )
        end)
      end)

      run_unboxed(fn ->
        scheduled_fixture.identity_ids
        |> Enum.at(1)
        |> then(&Repo.get!(UpstreamIdentity, &1))
        |> update_saved_resets!(scheduled_saved_resets(scheduled_fixture.as_of, 60 * 60))
      end)

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               run_unboxed(fn ->
                 manual_fixture.assignment_ids
                 |> Enum.at(1)
                 |> SavedResetRedemption.redeem(started_at: manual_fixture.as_of)
               end)

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               run_unboxed(fn ->
                 SavedResetRedemption.redeem_scheduled_expiry(
                   Enum.at(scheduled_fixture.assignment_ids, 1),
                   Enum.at(scheduled_fixture.identity_ids, 1),
                   started_at: scheduled_fixture.as_of
                 )
               end)

      assert provider_consume_count(manual_fake) == 1
      assert provider_consume_count(scheduled_fake) == 1
    end

    test "applied manual and scheduled consumes arm a later gateway-auto sibling fence" do
      {:ok, manual_fake} = codex_reset_fake(0)
      {:ok, scheduled_fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(manual_fake) end)
      on_exit(fn -> FakeUpstream.stop(scheduled_fake) end)

      manual_fixture = committed_gateway_auto_cohort_fixture!(manual_fake, :same_pool, 2)
      scheduled_fixture = committed_gateway_auto_cohort_fixture!(scheduled_fake, :same_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(manual_fixture) end)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(scheduled_fixture) end)

      run_unboxed(fn ->
        scheduled_fixture.identity_ids
        |> List.first()
        |> then(&Repo.get!(UpstreamIdentity, &1))
        |> update_saved_resets!(scheduled_saved_resets(scheduled_fixture.as_of, 60 * 60))
      end)

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               run_unboxed(fn ->
                 manual_fixture.assignment_ids
                 |> List.first()
                 |> SavedResetRedemption.redeem(started_at: manual_fixture.as_of)
               end)

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               run_unboxed(fn ->
                 SavedResetRedemption.redeem_scheduled_expiry(
                   List.first(scheduled_fixture.assignment_ids),
                   List.first(scheduled_fixture.identity_ids),
                   started_at: scheduled_fixture.as_of
                 )
               end)

      for {fixture, fake} <- [
            {manual_fixture, manual_fake},
            {scheduled_fixture, scheduled_fake}
          ] do
        assert {:ok,
                %{
                  status: :noop,
                  applied?: false,
                  code: "gateway_auto_sibling_consume_barrier"
                }} =
                 run_unboxed(fn ->
                   redeem_gateway_auto_target!(fixture, 1, fixture.identity_ids)
                 end)

        assert provider_consume_count(fake) == 1
      end
    end

    @tag :saved_reset_cohort_lock_same_pool
    @tag :saved_reset_sibling_barrier_concurrency
    test "mutually visible targets in one Pool serialize on their ordered cohort rows" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      evidence =
        run_gateway_auto_cohort_race!(
          fixture,
          0,
          Enum.reverse(fixture.identity_ids),
          1,
          fixture.identity_ids
        )

      assert evidence.winner_backend_pid != evidence.loser_backend_pid
      assert evidence.winner_backend_pid in evidence.blocking_pids
      assert evidence.wait_event_type == "Lock"
      assert {:ok, %{status: :succeeded, applied?: true}} = evidence.winner_result

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_sibling_consume_barrier"
              }} = evidence.loser_result

      assert evidence.winner_committed_before_loser_lock?
      assert provider_consume_count(fake) == 1
    end

    @tag :saved_reset_cohort_lock_cross_pool
    test "mutually visible targets across Pools serialize on the shared ordered cohort" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :cross_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      evidence =
        run_gateway_auto_cohort_race!(fixture, 0, fixture.identity_ids, 1, fixture.identity_ids)

      assert evidence.winner_backend_pid != evidence.loser_backend_pid
      assert evidence.winner_backend_pid in evidence.blocking_pids
      assert evidence.wait_event_type == "Lock"
      assert {:ok, %{status: :succeeded, applied?: true}} = evidence.winner_result

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_sibling_consume_barrier"
              }} = evidence.loser_result

      assert evidence.winner_committed_before_loser_lock?
      assert provider_consume_count(fake) == 1
    end

    test "recent or unresolved sibling lifecycles block gateway auto before provider I/O" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      recent_at = DateTime.add(fixture.as_of, -5, :minute)
      just_inside_floor = DateTime.add(fixture.as_of, -1_799_999, :millisecond)
      old_at = DateTime.add(fixture.as_of, -40, :minute)

      cases = [
        {"confirmed_by_quota", true, recent_at, "gateway_auto"},
        {"confirmed_by_quota", true, just_inside_floor, "gateway_auto"},
        {"reblocked", true, recent_at, "gateway_auto"},
        {"confirmed_by_quota", true, recent_at, "admin_manual"},
        {"confirmed_by_quota", true, recent_at, "scheduled_expiry_rescue"},
        {"consuming", false, old_at, "gateway_auto"},
        {"consumed_pending_probe", true, old_at, "gateway_auto"},
        {"confirmed_by_upstream", true, old_at, "gateway_auto"},
        {"expired", true, old_at, "gateway_auto"},
        {"unknown_phase", false, old_at, "gateway_auto"}
      ]

      for {phase, applied?, consumed_at, trigger_kind} <- cases do
        run_unboxed(fn ->
          fixture.identity_ids
          |> List.first()
          |> then(&Repo.get!(UpstreamIdentity, &1))
          |> update_redemption!(sibling_redemption(phase, consumed_at, applied?, trigger_kind))
        end)

        assert {:ok,
                %{
                  status: :noop,
                  applied?: false,
                  code: "gateway_auto_sibling_consume_barrier"
                }} =
                 run_unboxed(fn ->
                   redeem_gateway_auto_target!(fixture, 1, fixture.identity_ids)
                 end)
      end

      assert provider_consume_count(fake) == 0
    end

    test "resolved sibling lifecycles release at the floor or from exact non-application" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      cases = [
        {"confirmed_by_quota", true, -30},
        {"reblocked", true, -30},
        {"consume_not_applied", false, -5}
      ]

      Enum.with_index(cases, 1)
      |> Enum.each(fn {{phase, applied?, minutes}, expected_consume_count} ->
        fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
        on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

        run_unboxed(fn ->
          fixture.identity_ids
          |> List.first()
          |> then(&Repo.get!(UpstreamIdentity, &1))
          |> update_redemption!(
            sibling_redemption(
              phase,
              DateTime.add(fixture.as_of, minutes, :minute),
              applied?
            )
          )
        end)

        assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
                 run_unboxed(fn ->
                   redeem_gateway_auto_target!(fixture, 1, fixture.identity_ids)
                 end)

        assert provider_consume_count(fake) == expected_consume_count
      end)
    end

    test "an ambiguous sibling consume keeps the cohort fenced without a second POST" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:sequence,
           [
             {:json, 500, %{"error" => "synthetic failure"}},
             {:json, 200, %{"code" => "reset"}},
             {:json, 200, usage_payload(0)}
           ]}
        )

      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               run_unboxed(fn ->
                 redeem_gateway_auto_target!(fixture, 0, fixture.identity_ids)
               end)

      assert {:ok,
              %{status: :noop, applied?: false, code: "gateway_auto_sibling_consume_barrier"}} =
               run_unboxed(fn ->
                 redeem_gateway_auto_target!(fixture, 1, fixture.identity_ids)
               end)

      assert provider_consume_count(fake) == 1
    end

    @tag :saved_reset_cohort_lock_reversed_order
    test "reversed cohort input order normalizes to one lock order without deadlock" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      evidence =
        run_gateway_auto_cohort_race!(
          fixture,
          0,
          Enum.reverse(fixture.identity_ids) ++ [List.first(fixture.identity_ids)],
          1,
          fixture.identity_ids ++ [List.last(fixture.identity_ids)]
        )

      assert evidence.winner_backend_pid in evidence.blocking_pids
      assert evidence.winner_lock_ids == Enum.sort(fixture.identity_ids)
      assert evidence.loser_lock_ids == Enum.sort(fixture.identity_ids)
      assert {:ok, %{status: :succeeded}} = evidence.winner_result

      assert {:ok, %{status: :noop, code: "gateway_auto_sibling_consume_barrier"}} =
               evidence.loser_result
    end

    @tag :saved_reset_cohort_lock_disjoint
    test "disjoint cohorts do not block one another" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :cross_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      evidence =
        run_disjoint_gateway_auto_claims!(
          fixture,
          0,
          [Enum.at(fixture.identity_ids, 0)],
          1,
          [Enum.at(fixture.identity_ids, 1)]
        )

      assert evidence.winner_backend_pid != evidence.loser_backend_pid
      assert evidence.loser_blocking_pids == []
      assert {:ok, %{status: :succeeded}} = evidence.winner_result
      assert {:ok, %{status: :succeeded}} = evidence.loser_result
    end

    @tag :saved_reset_cohort_lock_partial_overlap
    test "partial non-target overlap serializes the row but provides no transitive target fence" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :cross_pool, 3)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      [first_id, shared_id, third_id] = fixture.identity_ids

      evidence =
        run_gateway_auto_cohort_race!(fixture, 0, [first_id, shared_id], 2, [shared_id, third_id])

      assert evidence.winner_backend_pid in evidence.blocking_pids
      assert first_id not in evidence.loser_lock_ids
      assert third_id not in evidence.winner_lock_ids
      assert {:ok, %{status: :succeeded, applied?: true}} = evidence.winner_result
      assert {:ok, %{status: :succeeded, applied?: true}} = evidence.loser_result
      assert provider_consume_count(fake) == 2
    end

    @tag :saved_reset_cohort_lock_exact_set
    test "a deleted cohort member returns context mismatch without provider I/O" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      [target_id, deleted_id] = fixture.identity_ids

      run_unboxed(fn ->
        Repo.delete_all(from identity in UpstreamIdentity, where: identity.id == ^deleted_id)
      end)

      assert {:ok, %{status: :noop, applied?: false, code: "gateway_auto_context_mismatch"}} =
               run_unboxed(fn ->
                 redeem_gateway_auto_target!(fixture, 0, [deleted_id, target_id, deleted_id])
               end)

      assert [] = FakeUpstream.requests(fake)

      persisted = run_unboxed(fn -> Repo.get!(UpstreamIdentity, target_id) end)
      assert get_in(persisted.metadata, ["saved_reset_redemption"]) == nil
    end

    @tag :saved_reset_cohort_lock_200
    test "a 200-member cohort uses one exact ordered identity lock and one assignment lock" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 200)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      input_ids =
        Enum.reverse(fixture.identity_ids) ++
          [List.first(fixture.identity_ids), List.last(fixture.identity_ids)]

      {result, lock_events, requests_while_locked} =
        capture_gateway_auto_claim_locks_until_identity_update!(fixture, 0, input_ids)

      assert {:ok, %{status: :succeeded, applied?: true}} = result
      assert requests_while_locked == []
      assert length(lock_events) == 2

      assert [cohort_lock, assignment_lock] = lock_events
      assert cohort_lock.source == "upstream_identities"
      assert cohort_lock.cohort_query?
      assert cohort_lock.row_count == 200
      assert cohort_lock.lock_ids == Enum.sort(fixture.identity_ids)
      assert cohort_lock.parameter_count == 1
      assert cohort_lock.query =~ "ANY($1::uuid[])"
      assert cohort_lock.query =~ ~r/ORDER BY .*\."id" FOR UPDATE/

      assert assignment_lock.source == "pool_upstream_assignments"
      refute assignment_lock.cohort_query?
      assert assignment_lock.row_count == 1
      assert assignment_lock.parameter_count == 1
    end

    @tag :saved_reset_expiry_ownership
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

    @tag :saved_reset_expiry_ownership
    @tag :separate_backend_automatic_claimant_race
    test "scheduled and gateway automatic claims share the identity consume latch" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_scheduled_expiry_race_fixture!(fake)
      on_exit(fn -> cleanup_committed_scheduled_expiry_race_fixture!(fixture) end)

      run_unboxed(fn ->
        identity = Repo.get!(UpstreamIdentity, fixture.identity_id)
        upsert_weekly_exhausted_quota!(identity)
      end)

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
              gateway_auto_context:
                gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion),
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

    @tag :saved_reset_expiry_ownership
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

    test "an ambiguous manual attempt retains exact-attempt ownership" do
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

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               SavedResetRedemption.redeem(assignment)

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:error, :redemption_in_progress} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [manual_consume] = FakeUpstream.requests(fake)
      assert manual_consume.path == "/api/codex/rate-limit-reset-credits/consume"
    end

    test "a recent reblocked sibling fences the threshold trigger" do
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
        cohort_identity_ids: [latched_identity.id, identity.id],
        route_class: "proxy_http"
      }

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_sibling_consume_barrier"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
      assert [] = FakeUpstream.requests(latched_fake)
    end

    test "threshold redemption noops after two cohort consumes when a sibling has usable capacity" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 3)
      on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)

      assert {:ok, %{status: :succeeded, applied?: true}} =
               run_unboxed(fn ->
                 redeem_gateway_auto_target!(fixture, 0, [Enum.at(fixture.identity_ids, 0)])
               end)

      assert {:ok, %{status: :succeeded, applied?: true}} =
               run_unboxed(fn ->
                 redeem_gateway_auto_target!(fixture, 1, [Enum.at(fixture.identity_ids, 1)])
               end)

      assert provider_consume_count(fake) == 2

      [first_id, second_id, target_id] = fixture.identity_ids
      released_at = DateTime.add(fixture.as_of, -31, :minute)

      run_unboxed(fn ->
        for identity_id <- [first_id, second_id] do
          identity_id
          |> then(&Repo.get!(UpstreamIdentity, &1))
          |> update_redemption!(sibling_redemption("confirmed_by_quota", released_at, true))
        end

        first_id
        |> then(&Repo.get!(UpstreamIdentity, &1))
        |> upsert_weekly_pressure_quota!(Decimal.new("10"),
          observed_at: fixture.as_of,
          last_sync_at: fixture.as_of,
          reset_at: DateTime.add(fixture.as_of, 2, :hour)
        )

        target_id
        |> then(&Repo.get!(UpstreamIdentity, &1))
        |> enable_saved_reset_auto_redeem!(%{
          saved_reset_auto_redeem_trigger_mode: "threshold",
          saved_reset_auto_redeem_quota_threshold_percent: 95
        })
        |> upsert_weekly_pressure_quota!(Decimal.new("96"),
          observed_at: fixture.as_of,
          last_sync_at: fixture.as_of,
          reset_at: DateTime.add(fixture.as_of, 2, :hour)
        )
      end)

      before_target = run_unboxed(fn -> Repo.get!(UpstreamIdentity, target_id).metadata end)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_sibling_usable_capacity"
              }} =
               run_unboxed(fn ->
                 redeem_gateway_auto_target!(fixture, 2, fixture.identity_ids,
                   trigger: :threshold_pressure,
                   candidate_identity_ids: [target_id]
                 )
               end)

      assert provider_consume_count(fake) == 2

      assert run_unboxed(fn -> Repo.get!(UpstreamIdentity, target_id).metadata end) ==
               before_target

      refute Jason.encode!(before_target) =~ "acct_cohort_lock"
    end

    test "threshold sibling capacity gate rejects unusable evidence without false vetoes" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      cases = [
        {:missing, [reset_at: nil]},
        {:stale,
         [
           observed_at: DateTime.add(DateTime.utc_now(), -2, :hour),
           last_sync_at: DateTime.add(DateTime.utc_now(), -2, :hour)
         ]},
        {:unknown_precision, [source_precision: "unknown"]},
        {:exhausted, [used_percent: Decimal.new("100")]},
        {:model_only,
         [
           quota_key: "other-model",
           quota_scope: "model",
           quota_family: "codex_model",
           model: "other-model"
         ]}
      ]

      Enum.with_index(cases, 1)
      |> Enum.each(fn {{scenario, sibling_overrides}, expected_consume_count} ->
        fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
        on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)
        [sibling_id, target_id] = fixture.identity_ids

        run_unboxed(fn ->
          target_id
          |> then(&Repo.get!(UpstreamIdentity, &1))
          |> enable_saved_reset_auto_redeem!(%{
            saved_reset_auto_redeem_trigger_mode: "threshold",
            saved_reset_auto_redeem_quota_threshold_percent: 95
          })
          |> upsert_weekly_pressure_quota!(Decimal.new("96"),
            observed_at: fixture.as_of,
            last_sync_at: fixture.as_of,
            reset_at: DateTime.add(fixture.as_of, 2, :hour)
          )

          sibling_overrides =
            Keyword.merge(
              [
                observed_at: fixture.as_of,
                last_sync_at: fixture.as_of,
                reset_at: DateTime.add(fixture.as_of, 2, :hour)
              ],
              sibling_overrides
            )

          sibling_id
          |> then(&Repo.get!(UpstreamIdentity, &1))
          |> upsert_weekly_pressure_quota!(
            Keyword.get(sibling_overrides, :used_percent, Decimal.new("10")),
            Keyword.delete(sibling_overrides, :used_percent)
          )
        end)

        assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
                 run_unboxed(fn ->
                   redeem_gateway_auto_target!(fixture, 1, fixture.identity_ids,
                     trigger: :threshold_pressure,
                     candidate_identity_ids: [target_id]
                   )
                 end),
               "scenario=#{scenario}"

        assert provider_consume_count(fake) == expected_consume_count,
               "scenario=#{scenario}"
      end)
    end

    test "hard exhaustion and session continuity bypass sibling usable capacity" do
      {:ok, fake} = codex_reset_fake(0)
      on_exit(fn -> FakeUpstream.stop(fake) end)

      for {trigger, context_overrides, target_percent, expected_consume_count} <- [
            {:blocked_weekly_exhaustion, %{}, Decimal.new("100"), 1},
            {:threshold_pressure, %{session_continuity?: true}, Decimal.new("96"), 2}
          ] do
        fixture = committed_gateway_auto_cohort_fixture!(fake, :same_pool, 2)
        on_exit(fn -> cleanup_committed_gateway_auto_cohort_fixture!(fixture) end)
        [sibling_id, target_id] = fixture.identity_ids

        run_unboxed(fn ->
          sibling_id
          |> then(&Repo.get!(UpstreamIdentity, &1))
          |> upsert_weekly_pressure_quota!(Decimal.new("10"),
            observed_at: fixture.as_of,
            last_sync_at: fixture.as_of,
            reset_at: DateTime.add(fixture.as_of, 2, :hour)
          )

          target = Repo.get!(UpstreamIdentity, target_id)

          target =
            if trigger == :threshold_pressure do
              enable_saved_reset_auto_redeem!(target, %{
                saved_reset_auto_redeem_trigger_mode: "threshold",
                saved_reset_auto_redeem_quota_threshold_percent: 95
              })
            else
              target
            end

          upsert_weekly_pressure_quota!(target, target_percent,
            observed_at: fixture.as_of,
            last_sync_at: fixture.as_of,
            reset_at: DateTime.add(fixture.as_of, 2, :hour)
          )
        end)

        assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
                 run_unboxed(fn ->
                   redeem_gateway_auto_target!(
                     fixture,
                     1,
                     fixture.identity_ids,
                     [trigger: trigger, candidate_identity_ids: [target_id]] ++
                       Map.to_list(context_overrides)
                   )
                 end)

        assert provider_consume_count(fake) == expected_consume_count
      end
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

  defp sibling_redemption(phase, consumed_at, applied?, trigger_kind \\ "gateway_auto") do
    status =
      if phase in ["consuming", "consumed_pending_probe"], do: "redeeming", else: "succeeded"

    %{
      "status" => status,
      "phase" => phase,
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => trigger_kind,
      "started_at" => DateTime.to_iso8601(consumed_at),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "finished_at" => DateTime.to_iso8601(consumed_at),
      "result" => %{"code" => "synthetic", "applied" => applied?}
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
    unique = Ecto.UUID.generate()

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

    active_upstream_assignment_fixture(pool_fixture(), %{
      chatgpt_account_id: "acct_#{unique}",
      account_label: "Gateway upstream #{unique}",
      metadata: metadata
    })
  end

  defp ambiguous_chatgpt_recovery_fixture! do
    credit_id = "credit_recovery_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/rate-limit-reset-credits" =>
             {200, %{"credits" => [%{"id" => credit_id, "status" => "available"}]}},
           "/backend-api/wham/rate-limit-reset-credits/consume" =>
             {503, %{"code" => "provider_failed"}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment} =
      assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

    assert {:error, :saved_reset_consume_outcome_ambiguous} =
             SavedResetRedemption.redeem(assignment)

    [_, consume_request] = FakeUpstream.requests(fake)
    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]

    {:ok, last_provider_dispatched_at, 0} =
      DateTime.from_iso8601(redemption["provider_replay"]["last_provider_dispatched_at"])

    %{
      assignment: assignment,
      attempt_id: redemption["attempt_id"],
      credit_id: credit_id,
      fake: fake,
      generation: redemption["generation"],
      identity: identity,
      last_provider_dispatched_at: last_provider_dispatched_at,
      redeem_request_id: consume_request.json["redeem_request_id"]
    }
  end

  defp ambiguous_codex_recovery_fixture! do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json, %{"/api/codex/rate-limit-reset-credits/consume" => :close_before_headers}}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{identity: identity, assignment: assignment} =
      assignment_with_fake(fake, "/api/codex/usage", "codex_api")

    assert {:error, :saved_reset_consume_outcome_ambiguous} =
             SavedResetRedemption.redeem(assignment)

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]

    {:ok, last_provider_dispatched_at, 0} =
      DateTime.from_iso8601(redemption["provider_replay"]["last_provider_dispatched_at"])

    %{
      assignment: assignment,
      attempt_id: redemption["attempt_id"],
      fake: fake,
      generation: redemption["generation"],
      identity: identity,
      last_provider_dispatched_at: last_provider_dispatched_at
    }
  end

  defp make_recovery_due!(fixture, now, opts \\ []) do
    persisted = Repo.reload!(fixture.identity)
    redemption = persisted.metadata["saved_reset_redemption"]
    replay = redemption["provider_replay"]

    last_provider_dispatched_at =
      Keyword.get(opts, :last_provider_dispatched_at, fixture.last_provider_dispatched_at)

    replay =
      replay
      |> Map.put(
        "provider_dispatches",
        Keyword.get(opts, :provider_dispatches, replay["provider_dispatches"])
      )
      |> Map.put(
        "last_provider_dispatched_at",
        DateTime.to_iso8601(last_provider_dispatched_at)
      )
      |> Map.put(
        "next_action_at",
        encode_test_datetime(Keyword.get(opts, :next_action_at, now))
      )

    redemption =
      redemption
      |> Map.put(
        "started_at",
        opts
        |> Keyword.get(:started_at, DateTime.add(now, -10, :minute))
        |> DateTime.to_iso8601()
      )
      |> Map.put("provider_replay", replay)

    identity = update_redemption!(persisted, redemption)
    %{fixture | identity: identity, last_provider_dispatched_at: last_provider_dispatched_at}
  end

  defp encode_test_datetime(nil), do: nil
  defp encode_test_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp resume_recovery(fixture, now) do
    SavedResetRedemption.resume_stale_consuming(
      fixture.assignment,
      fixture.identity.id,
      fixture.attempt_id,
      fixture.generation,
      now: now,
      receive_timeout: 1_000
    )
  end

  defp recovery_race_fake do
    FakeUpstream.start_link(:close_before_headers)
  end

  defp committed_chatgpt_recovery_fixture!(fake) do
    run_unboxed(fn ->
      credit_id = "credit_race_#{System.unique_integer([:positive, :monotonic])}"

      FakeUpstream.set_mode(fake, {
        :path_json,
        %{
          "/backend-api/wham/rate-limit-reset-credits" =>
            {200, %{"credits" => [%{"id" => credit_id, "status" => "available"}]}},
          "/backend-api/wham/rate-limit-reset-credits/consume" =>
            {503, %{"code" => "provider_failed"}}
        }
      })

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      assert {:error, :saved_reset_consume_outcome_ambiguous} =
               SavedResetRedemption.redeem(assignment)

      redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]

      {:ok, last_provider_dispatched_at, 0} =
        DateTime.from_iso8601(redemption["provider_replay"]["last_provider_dispatched_at"])

      now = DateTime.add(last_provider_dispatched_at, 60, :second)

      due_redemption =
        redemption
        |> Map.put("started_at", DateTime.to_iso8601(DateTime.add(now, -10, :minute)))
        |> put_in(["provider_replay", "next_action_at"], DateTime.to_iso8601(now))

      update_redemption!(identity, due_redemption)

      %{
        assignment_id: assignment.id,
        attempt_id: redemption["attempt_id"],
        credit_id: credit_id,
        generation: redemption["generation"],
        identity_id: identity.id,
        now: now,
        pool_id: assignment.pool_id
      }
    end)
  end

  defp cleanup_committed_recovery_fixture!(fixture) do
    run_unboxed(fn ->
      Repo.delete_all(
        from identity in UpstreamIdentity, where: identity.id == ^fixture.identity_id
      )

      Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool_id)
    end)
  end

  defp start_recovery_replica_task(parent, role, fixture) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn -> run_recovery_replica(parent, role, fixture) end)
    end)
  end

  defp run_recovery_replica(parent, role, fixture) do
    Repo.checkout(fn -> execute_recovery_replica(parent, role, fixture) end)
  end

  defp execute_recovery_replica(parent, role, fixture) do
    send(parent, {:recovery_replica_ready, role})

    receive do
      :start_recovery -> :ok
    after
      5_000 -> raise "timed out waiting to start saved-reset recovery replica"
    end

    result =
      SavedResetRedemption.resume_stale_consuming(
        fixture.assignment_id,
        fixture.identity_id,
        fixture.attempt_id,
        fixture.generation,
        now: fixture.now,
        receive_timeout: 1_000
      )

    {role, result}
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

  defp gateway_auto_context(assignment, identity, trigger, overrides \\ %{}) do
    Map.merge(
      %{
        trigger: trigger,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        candidate_assignment_ids: [assignment.id],
        candidate_identity_ids: [identity.id],
        cohort_identity_ids: [identity.id],
        route_class: "proxy_http",
        quota_scope: test_quota_scope(),
        session_continuity?: false
      },
      Map.new(overrides)
    )
  end

  defp test_quota_scope do
    %{
      requested_model: "test-model",
      catalog_model: "test-model",
      exposed_model_id: "test-model",
      upstream_model: "test-model",
      upstream_model_id: "test-model"
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

  defp upsert_weekly_pressure_quota!(identity, used_percent, overrides \\ []) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               weekly_quota_attrs(used_percent, overrides)
             ])
  end

  defp weekly_quota_attrs(used_percent, overrides) do
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
      unique = Ecto.UUID.generate()
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

  defp committed_gateway_auto_cohort_fixture!(fake, pool_mode, identity_count) do
    run_unboxed(fn ->
      unique = Ecto.UUID.generate()
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      pools = gateway_auto_cohort_pools(pool_mode, unique, identity_count)

      entries =
        Enum.map(0..(identity_count - 1), fn index ->
          pool = gateway_auto_cohort_pool(pools, pool_mode, index)

          %{assignment: assignment, identity: identity} =
            active_upstream_assignment_fixture(pool, %{
              account_label: "Cohort lock account #{unique} #{index}",
              chatgpt_account_id: "acct_cohort_lock_#{unique}_#{index}",
              metadata: %{
                "usage_base_url" => FakeUpstream.url(fake),
                "saved_resets" => %{
                  "status" => "reported",
                  "available_count" => 1,
                  "source" => "codex_usage_api",
                  "path_style" => "codex_api",
                  "observed_at" => DateTime.to_iso8601(as_of),
                  "usage_path" => "/api/codex/usage",
                  "reason" => nil
                }
              }
            })

          identity = enable_saved_reset_auto_redeem!(identity)

          upsert_weekly_exhausted_quota!(identity,
            observed_at: as_of,
            last_sync_at: as_of,
            reset_at: DateTime.add(as_of, 2, :hour)
          )

          %{assignment_id: assignment.id, identity_id: identity.id}
        end)

      %{
        as_of: as_of,
        assignment_ids: Enum.map(entries, & &1.assignment_id),
        fake: fake,
        identity_ids: Enum.map(entries, & &1.identity_id),
        pool_ids: Enum.map(pools, & &1.id)
      }
    end)
  end

  defp cleanup_committed_gateway_auto_cohort_fixture!(fixture) do
    run_unboxed(fn ->
      Repo.delete_all(
        from identity in UpstreamIdentity,
          where: identity.id in ^fixture.identity_ids
      )

      Repo.delete_all(from pool in Pool, where: pool.id in ^fixture.pool_ids)
    end)
  end

  defp gateway_auto_cohort_pool(pools, :same_pool, _index), do: List.first(pools)
  defp gateway_auto_cohort_pool(pools, :cross_pool, index), do: Enum.at(pools, index)

  defp gateway_auto_cohort_pools(:same_pool, unique, _identity_count) do
    [pool_fixture(%{slug: "cohort-lock-#{unique}"})]
  end

  defp gateway_auto_cohort_pools(:cross_pool, unique, identity_count) do
    Enum.map(1..identity_count, fn index ->
      pool_fixture(%{slug: "cohort-lock-#{unique}-#{index}"})
    end)
  end

  defp redeem_gateway_auto_target!(fixture, target_index, cohort_identity_ids, opts \\ []) do
    assignment = Repo.get!(PoolUpstreamAssignment, Enum.at(fixture.assignment_ids, target_index))
    identity = Repo.get!(UpstreamIdentity, Enum.at(fixture.identity_ids, target_index))

    trigger = Keyword.get(opts, :trigger, :blocked_weekly_exhaustion)

    context_overrides =
      opts
      |> Keyword.drop([:trigger])
      |> Map.new()
      |> Map.put_new(:routable_identity_ids, cohort_identity_ids)

    context =
      assignment
      |> gateway_auto_context(identity, trigger, context_overrides)
      |> Map.put(:cohort_identity_ids, cohort_identity_ids)

    SavedResetRedemption.redeem(assignment,
      trigger_kind: "gateway_auto",
      gateway_auto_context: context,
      started_at: fixture.as_of,
      receive_timeout: 15_000
    )
  end

  defp run_gateway_auto_cohort_race!(
         fixture,
         winner_index,
         winner_cohort_ids,
         loser_index,
         loser_cohort_ids
       ) do
    parent = self()
    barrier = make_ref()

    winner_task =
      start_gateway_auto_claim_task(
        parent,
        barrier,
        :winner,
        fixture,
        winner_index,
        winner_cohort_ids
      )

    loser_task =
      start_gateway_auto_claim_task(
        parent,
        barrier,
        :loser,
        fixture,
        loser_index,
        loser_cohort_ids
      )

    tasks = [winner_task, loser_task]
    handler_id = {__MODULE__, :cohort_race, System.unique_integer([:positive, :monotonic])}

    :ok = attach_gateway_auto_cohort_barrier(handler_id, parent, barrier)

    try do
      assert_receive {^barrier, :claim_ready, :winner, winner_backend_pid}, 5_000
      assert_receive {^barrier, :claim_ready, :loser, loser_backend_pid}, 5_000
      assert winner_backend_pid != loser_backend_pid

      send(winner_task.pid, {barrier, :start_claim})

      assert_receive {^barrier, :cohort_locked, :winner, winner_claim_pid, winner_lock_event},
                     5_000

      send(loser_task.pid, {barrier, :start_claim})
      assert_receive {^barrier, :claim_started, :loser, ^loser_backend_pid}, 5_000

      observation = observe_blocked_probe_claim!(loser_backend_pid, winner_backend_pid)
      send(winner_claim_pid, {barrier, :release_cohort_lock})

      assert_receive {^barrier, :cohort_locked, :loser, loser_claim_pid, loser_lock_event}, 5_000

      winner_identity_id = Enum.at(fixture.identity_ids, winner_index)

      winner_committed_before_loser_lock? =
        run_unboxed(fn ->
          identity = Repo.get!(UpstreamIdentity, winner_identity_id)
          is_map(get_in(identity.metadata, ["saved_reset_redemption"]))
        end)

      send(loser_claim_pid, {barrier, :release_cohort_lock})

      {:winner, ^winner_backend_pid, winner_result} = Task.await(winner_task, 15_000)
      {:loser, ^loser_backend_pid, loser_result} = Task.await(loser_task, 15_000)

      %{
        blocking_pids: observation.blocking_pids,
        loser_backend_pid: loser_backend_pid,
        loser_lock_ids: loser_lock_event.lock_ids,
        loser_result: loser_result,
        wait_event_type: observation.wait_event_type,
        winner_backend_pid: winner_backend_pid,
        winner_committed_before_loser_lock?: winner_committed_before_loser_lock?,
        winner_lock_ids: winner_lock_event.lock_ids,
        winner_result: winner_result
      }
    after
      :telemetry.detach(handler_id)
      release_gateway_auto_claim_tasks(tasks, barrier)
    end
  end

  defp run_disjoint_gateway_auto_claims!(
         fixture,
         winner_index,
         winner_cohort_ids,
         loser_index,
         loser_cohort_ids
       ) do
    parent = self()
    barrier = make_ref()

    winner_task =
      start_gateway_auto_claim_task(
        parent,
        barrier,
        :winner,
        fixture,
        winner_index,
        winner_cohort_ids
      )

    loser_task =
      start_gateway_auto_claim_task(
        parent,
        barrier,
        :loser,
        fixture,
        loser_index,
        loser_cohort_ids
      )

    tasks = [winner_task, loser_task]
    handler_id = {__MODULE__, :disjoint_cohort, System.unique_integer([:positive, :monotonic])}
    :ok = attach_gateway_auto_cohort_barrier(handler_id, parent, barrier)

    try do
      assert_receive {^barrier, :claim_ready, :winner, winner_backend_pid}, 5_000
      assert_receive {^barrier, :claim_ready, :loser, loser_backend_pid}, 5_000

      send(winner_task.pid, {barrier, :start_claim})

      assert_receive {^barrier, :cohort_locked, :winner, winner_claim_pid, _winner_lock_event},
                     5_000

      send(loser_task.pid, {barrier, :start_claim})

      assert_receive {^barrier, :cohort_locked, :loser, loser_claim_pid, _loser_lock_event},
                     5_000

      loser_blocking_pids = blocking_pids!(loser_backend_pid)

      send(winner_claim_pid, {barrier, :release_cohort_lock})
      send(loser_claim_pid, {barrier, :release_cohort_lock})

      {:winner, ^winner_backend_pid, winner_result} = Task.await(winner_task, 15_000)
      {:loser, ^loser_backend_pid, loser_result} = Task.await(loser_task, 15_000)

      %{
        loser_backend_pid: loser_backend_pid,
        loser_blocking_pids: loser_blocking_pids,
        loser_result: loser_result,
        winner_backend_pid: winner_backend_pid,
        winner_result: winner_result
      }
    after
      :telemetry.detach(handler_id)
      release_gateway_auto_claim_tasks(tasks, barrier)
    end
  end

  defp start_gateway_auto_claim_task(
         parent,
         barrier,
         role,
         fixture,
         target_index,
         cohort_identity_ids
       ) do
    Task.async(fn ->
      run_gateway_auto_claim_task(
        parent,
        barrier,
        role,
        fixture,
        target_index,
        cohort_identity_ids
      )
    end)
  end

  defp run_gateway_auto_claim_task(
         parent,
         barrier,
         role,
         fixture,
         target_index,
         cohort_identity_ids
       ) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.checkout(fn ->
        execute_gateway_auto_claim(
          parent,
          barrier,
          role,
          fixture,
          target_index,
          cohort_identity_ids
        )
      end)
    end)
  end

  defp execute_gateway_auto_claim(
         parent,
         barrier,
         role,
         fixture,
         target_index,
         cohort_identity_ids
       ) do
    backend_pid = backend_pid!()
    Process.put({__MODULE__, barrier, :role}, role)
    send(parent, {barrier, :claim_ready, role, backend_pid})

    receive do
      {^barrier, :start_claim} -> :ok
    after
      5_000 -> raise "timed out waiting to start gateway-auto cohort claim"
    end

    send(parent, {barrier, :claim_started, role, backend_pid})

    try do
      {role, backend_pid, redeem_gateway_auto_target!(fixture, target_index, cohort_identity_ids)}
    after
      Process.delete({__MODULE__, barrier, :role})
    end
  end

  defp attach_gateway_auto_cohort_barrier(handler_id, parent, barrier) do
    :telemetry.attach(
      handler_id,
      [:codex_pooler, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        role = Process.get({__MODULE__, barrier, :role})

        if role in [:winner, :loser] and cohort_identity_lock_query?(metadata) do
          send(parent, {barrier, :cohort_locked, role, self(), claim_lock_event(metadata)})

          receive do
            {^barrier, :release_cohort_lock} -> :ok
          after
            10_000 -> raise "timed out waiting to release gateway-auto cohort lock"
          end
        end
      end,
      nil
    )
  end

  defp release_gateway_auto_claim_tasks(tasks, barrier) do
    Enum.each(tasks, fn task ->
      send(task.pid, {barrier, :start_claim})
      send(task.pid, {barrier, :release_cohort_lock})
    end)

    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: release_probe_claim_task(task)
    end)
  end

  defp capture_claim_locks_until_identity_update!(claim_fun) do
    handler_id = {__MODULE__, :claim_locks, System.unique_integer([:positive, :monotonic])}
    process_key = {__MODULE__, handler_id, :capture?}
    Process.put(process_key, true)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          capture_claim_lock_event(metadata, process_key)
        end,
        nil
      )

    try do
      result = claim_fun.()
      {result, process_key |> then(&Process.get({&1, :locks}, [])) |> Enum.reverse()}
    after
      :telemetry.detach(handler_id)
      Process.delete(process_key)
      Process.delete({process_key, :locks})
    end
  end

  defp capture_claim_lock_event(metadata, process_key) do
    if Process.get(process_key) do
      cond do
        claim_lock_query?(metadata) ->
          Process.put({process_key, :locks}, [
            claim_lock_event(metadata) | Process.get({process_key, :locks}, [])
          ])

        identity_update_query?(metadata) ->
          Process.put(process_key, false)

        true ->
          :ok
      end
    end
  end

  defp capture_gateway_auto_claim_locks_until_identity_update!(fixture, target_index, cohort_ids) do
    parent = self()
    barrier = make_ref()
    handler_id = {__MODULE__, :claim_shape, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          capture_gateway_auto_claim_event(metadata, parent, barrier)
        end,
        nil
      )

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put({__MODULE__, barrier, :capture?}, true)

          try do
            redeem_gateway_auto_target!(fixture, target_index, cohort_ids)
          after
            Process.delete({__MODULE__, barrier, :capture?})
          end
        end)
      end)

    try do
      assert_receive {^barrier, :claim_persisted, claim_pid}, 10_000
      lock_events = drain_claim_locks(barrier, [])
      requests_while_locked = FakeUpstream.requests(fixture.fake)
      send(claim_pid, {barrier, :release_claim})
      {Task.await(task, 15_000), lock_events, requests_while_locked}
    after
      send(task.pid, {barrier, :release_claim})
      :telemetry.detach(handler_id)
      release_probe_claim_task(task)
    end
  end

  defp capture_gateway_auto_claim_event(metadata, parent, barrier) do
    if Process.get({__MODULE__, barrier, :capture?}) do
      cond do
        claim_lock_query?(metadata) ->
          send(parent, {barrier, :claim_lock, claim_lock_event(metadata)})

        identity_update_query?(metadata) ->
          Process.put({__MODULE__, barrier, :capture?}, false)
          send(parent, {barrier, :claim_persisted, self()})

          receive do
            {^barrier, :release_claim} -> :ok
          after
            5_000 -> raise "timed out waiting to release captured gateway-auto claim"
          end

        true ->
          :ok
      end
    end
  end

  defp drain_claim_locks(barrier, events) do
    receive do
      {^barrier, :claim_lock, event} -> drain_claim_locks(barrier, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp claim_lock_query?(metadata) do
    metadata[:repo] == Repo and
      metadata[:source] in ["upstream_identities", "pool_upstream_assignments"] and
      is_binary(metadata[:query]) and String.contains?(metadata[:query], "FOR UPDATE")
  end

  defp cohort_identity_lock_query?(metadata) do
    metadata[:repo] == Repo and metadata[:source] == "upstream_identities" and
      is_binary(metadata[:query]) and String.contains?(metadata[:query], "ANY(") and
      String.contains?(metadata[:query], "FOR UPDATE")
  end

  defp claim_lock_event(metadata) do
    %{
      cohort_query?: cohort_identity_lock_query?(metadata),
      lock_ids: lock_query_ids(metadata[:params]),
      parameter_count: length(List.wrap(metadata[:params])),
      query: metadata[:query],
      row_count: repo_query_row_count(metadata[:result]),
      source: metadata[:source]
    }
  end

  defp lock_query_ids([ids]) when is_list(ids) do
    ids
    |> Enum.map(fn
      <<_::128>> = id ->
        {:ok, uuid} = Ecto.UUID.load(id)
        uuid

      id when is_binary(id) ->
        id
    end)
    |> Enum.sort()
  end

  defp lock_query_ids(_params), do: []

  defp repo_query_row_count({:ok, %{num_rows: row_count}}), do: row_count
  defp repo_query_row_count(%{num_rows: row_count}), do: row_count
  defp repo_query_row_count(_result), do: 0

  defp blocking_pids!(backend_pid) do
    run_unboxed(fn ->
      %{rows: [[blocking_pids]]} =
        SQL.query!(
          Repo,
          "SELECT pg_blocking_pids($1) FROM pg_stat_activity WHERE pid = $1",
          [backend_pid]
        )

      blocking_pids
    end)
  end

  defp install_saved_reset_finalization_failure_trigger!(identity_id) do
    trigger_name =
      "reject_saved_reset_finalization_#{System.unique_integer([:positive, :monotonic])}"

    SQL.query!(
      Repo,
      """
      CREATE FUNCTION pg_temp.reject_saved_reset_finalization() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.id = '#{identity_id}'::uuid
           AND OLD.metadata #>> '{saved_reset_redemption,provider_replay,provider_dispatches}' = '1'
           AND NEW.metadata #>> '{saved_reset_redemption,status}' <> 'redeeming' THEN
          RAISE EXCEPTION 'synthetic saved-reset finalization failure';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TRIGGER #{trigger_name}
      BEFORE UPDATE ON upstream_identities
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_saved_reset_finalization()
      """,
      []
    )
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

  defp provider_credit_consume_count(fake) do
    fake
    |> FakeUpstream.requests()
    |> Enum.count(&String.ends_with?(&1.path, "/rate-limit-reset-credits/consume"))
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
    |> Task.await(15_000)
  end
end
