defmodule CodexPooler.Upstreams.SavedResets.HistoricalManualRedemptionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.{FakeUpstream, ProviderCreditsFixtures, Repo}
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.{CapacityFactsStore, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.{Convergence, CreditLocator, ManualRedemptionGate, RedemptionLifecycle}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  test "an explicit manual request replaces an expired empty binding only after a later confirmed exhausted cycle" do
    fixture = fixture!()
    original = fixture.identity.metadata["saved_reset_redemption"]
    assert RedemptionLifecycle.blocks_new_redemption?(original, fixture.now)
    assert RedemptionLifecycle.gateway_auto_latch(original, fixture.now) == :blocked_awaiting_quota

    assert {:ok, _, _} = SavedResetRedemption.ensure_manual_available(fixture.assignment)
    assert Repo.reload!(fixture.identity).metadata["saved_reset_redemption"] == original
    assert {:ok, %{applied?: true}} = SavedResetRedemption.redeem(fixture.assignment)

    current = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
    refute current["attempt_id"] == original["attempt_id"]
    assert current["generation"] == original["generation"] + 1
    assert current["included_window_descriptors"] == [%{"window_kind" => "secondary", "window_minutes" => 10_080}]
    assert FakeUpstream.physical_counts(fixture.fake).consume == 1
    assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(fixture.assignment)
    assert FakeUpstream.physical_counts(fixture.fake).consume == 1
  end

  test "a later-cycle manual request enters the real unique job queue without altering the old receipt" do
    fixture = fixture!()
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(user, ["instance_owner"])
    assert {:ok, %{status: :queued, job: first}} = Upstreams.enqueue_saved_reset_redemption_for_scope(scope, fixture.identity, fixture.assignment.pool_id)
    assert {:ok, %{status: :already_queued, job: second}} = Upstreams.enqueue_saved_reset_redemption_for_scope(scope, fixture.identity, fixture.assignment.pool_id)
    assert first.id == second.id
    assert Repo.reload!(fixture.identity).metadata["saved_reset_redemption"] == fixture.identity.metadata["saved_reset_redemption"]
    assert FakeUpstream.physical_counts(fixture.fake).consume == 0
  end

  test "an applied historical replacement confirms at the guarded recovery boundary and routes before the old runtime quota expires" do
    fixture = fixture!()
    assert {:ok, %{applied?: true}} = SavedResetRedemption.redeem(fixture.assignment)
    identity = Repo.reload!(fixture.identity)
    real_claim = identity.metadata["saved_reset_redemption"]
    assert real_claim["provider_replay"]["version"] == 2
    assert real_claim["phase"] == "consumed_pending_probe"

    # Move only this fixture's real claim into a synthetic elapsed timeline;
    # the producer still has to establish recovery through its 180-second guard.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    candidate_at = DateTime.add(now, -180)
    consumed_at = DateTime.add(candidate_at, -60)
    canonical_at = DateTime.add(candidate_at, -300)
    {:ok, actual_consumed_at, 0} = DateTime.from_iso8601(real_claim["consumed_at"])
    shifted = shift_times(real_claim, DateTime.diff(consumed_at, actual_consumed_at, :microsecond))
    identity = identity |> change(metadata: Map.put(identity.metadata, "saved_reset_redemption", shifted)) |> Repo.update!()
    Repo.delete_all(from window in CodexPooler.Upstreams.Quota.AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id)
    old_reset = DateTime.add(canonical_at, 5, :day)
    assert {:ok, _} = Windows.record_evidence(identity, recovery_window(100, canonical_at, old_reset), canonical_at)
    exhausted_at = DateTime.add(consumed_at, -30)
    assert {:ok, old_runtime} = Windows.record_evidence(identity, Map.put(recovery_window(100, exhausted_at, old_reset), :source, "codex_rate_limit_event"), exhausted_at)
    assert {:ok, pending} = Windows.record_evidence(identity, recovery_window(0, candidate_at, DateTime.add(candidate_at, 604_800)), candidate_at)
    assert {:ok, %{observed_at: ^candidate_at}} = EvidenceStore.parse_candidate(pending.metadata)

    below = DateTime.add(candidate_at, 179)
    refresh_recovered_usage!(fixture, below)
    assert {:ok, :unchanged} = Convergence.converge(identity.id, below, "reconciliation")
    below_snapshot = Map.fetch!(Windows.load_routing_quota_snapshots([identity.id], below), identity.id)
    refute Windows.routing_quota_eligibility_from_snapshot(below_snapshot).eligible?
    refresh_recovered_usage!(fixture, now)
    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity.id, now, "reconciliation")
    confirmed = Repo.reload!(identity)
    assert confirmed.metadata["saved_reset_redemption"]["phase"] == "confirmed_by_quota"
    assert ManualRedemptionGate.stored_context_valid?(confirmed.metadata["saved_reset_redemption"]["manual_replacement"], now)
    snapshot = Map.fetch!(Windows.load_routing_quota_snapshots([identity.id], now), identity.id)
    assert snapshot.capacity_facts.included_permission == :available
    assert CapacityFactsStore.fresh?(snapshot.capacity_facts, snapshot.credential_epoch, now)
    assert Windows.routing_quota_eligibility_from_snapshot(snapshot).eligible?
    [display_window] = RoutingQuotaSnapshot.effective_windows(snapshot)
    assert Decimal.equal?(display_window.used_percent, 0)
    assert Decimal.equal?(Repo.reload!(old_runtime).used_percent, 100)
    assert DateTime.diff(now, old_runtime.observed_at) < 900
    assert FakeUpstream.physical_counts(fixture.fake).consume == 1

    receipt = confirmed.metadata["saved_reset_redemption"]

    for invalid <- [Map.delete(receipt, "manual_replacement"), Map.put(receipt, "manual_replacement", %{}), Map.put(receipt, "trigger_kind", "gateway_auto"), put_in(receipt, ["provider_replay", "version"], 3)] do
      changed = %{snapshot | redemption: invalid}
      refute Windows.routing_quota_eligibility_from_snapshot(changed).eligible?
      assert old_runtime.id in Enum.map(RoutingQuotaSnapshot.effective_windows(changed), & &1.id)
    end
  end

  defp recovery_window(percent, at, reset_at) do
    %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, used_percent: Decimal.new(percent), reset_at: reset_at, observed_at: at, last_sync_at: at, source: "codex_usage_api", source_precision: "observed", freshness_state: "fresh", metadata: %{"credential_epoch" => 15, "reset_after_seconds" => DateTime.diff(reset_at, at), "rate_limit_allowed" => percent < 100, "rate_limit_reached" => percent >= 100}}
  end

  defp refresh_recovered_usage!(fixture, at) do
    payload = %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 1}, "rate_limit" => %{"allowed" => true, "limit_reached" => false, "secondary_window" => %{"used_percent" => 0, "limit_window_seconds" => 604_800, "reset_after_seconds" => 604_800, "reset_at" => DateTime.to_unix(DateTime.add(at, 604_800))}}}
    FakeUpstream.set_mode(fixture.fake, {:path_json, ProviderCreditsFixtures.usage_routes(payload)})
    assert {:ok, _} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(fixture.identity), fixture.assignment, observed_at: at)
  end

  defp shift_times(value, delta) when is_map(value), do: Map.new(value, fn {key, child} -> {key, shift_times(child, delta)} end)

  defp shift_times(value, delta) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, 0} -> at |> DateTime.add(delta, :microsecond) |> DateTime.to_iso8601()
      _other -> value
    end
  end

  defp shift_times(value, _delta), do: value

  for invalid <- [:missing_binding, :nonempty_binding, :unapplied, :unknown_code, :inflight, :unknown_phase, :bad_attempt, :bad_generation, :no_dispatch, :too_many_dispatches, :bad_replay, :future_finish, :reversed_clocks, :cooldown, :same_cycle, :near_cycle, :floating, :stale, :future_observation, :future_provider, :stale_provider, :future_confirmation, :malformed_marker, :wrong_epoch, :missing_epoch, :monthly, :wrong_source, :wrong_scope, :moving_reset] do
    test "#{invalid} remains blocked without replacing the historical receipt or consuming" do
      fixture = fixture!() |> invalidate!(unquote(invalid))
      identity = Repo.reload!(fixture.identity)
      original = identity.metadata["saved_reset_redemption"]

      assert SavedResets.manual_redemption_blocked?(identity, Windows.list_evidence(identity), DateTime.utc_now())
      assert {:error, %{code: :saved_reset_redemption_in_progress}} = SavedResetRedemption.ensure_manual_available(fixture.assignment)
      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(fixture.assignment)
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == original
      assert FakeUpstream.physical_counts(fixture.fake).consume == 0
    end
  end

  test "a provider no-op replacement retains the automatic hold until another explicit manual request applies" do
    fixture = fixture!()
    FakeUpstream.set_mode(fixture.fake, {:path_json, Map.put(fixture.routes, "/backend-api/wham/rate-limit-reset-credits/consume", {200, %{"code" => "nothing_to_reset"}})})
    assert {:ok, %{applied?: false}} = SavedResetRedemption.redeem(fixture.assignment)
    receipt = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
    assert RedemptionLifecycle.blocks_new_redemption?(receipt, DateTime.utc_now())
    assert RedemptionLifecycle.gateway_auto_latch(receipt, DateTime.utc_now()) == :blocked_awaiting_quota
    assert RedemptionLifecycle.gateway_auto_sibling_fence(receipt, DateTime.utc_now()) == :blocked_awaiting_quota
    FakeUpstream.set_mode(fixture.fake, {:path_json, fixture.routes})
    assert {:ok, %{applied?: true}} = SavedResetRedemption.redeem(fixture.assignment)
    assert FakeUpstream.physical_counts(fixture.fake).consume == 2
  end

  for changed <- [:epoch, :cycle] do
    test "a fresh explicit manual request rebuilds its proof after a cancelled attempt and #{changed} advancement" do
      fixture = fixture!()
      {task, gate_pid, ref} = gated_claim!(fixture)
      lose_proof!(fixture, :anchor)
      send(gate_pid, {:fake_upstream_release_gate, ref})
      assert {:ok, %{applied?: false}} = Task.await(task, 15_000)
      identity = Repo.reload!(fixture.identity)
      old_context = identity.metadata["saved_reset_redemption"]["manual_replacement"]
      epoch = if unquote(changed) == :epoch, do: 16, else: 15
      reset_at = if unquote(changed) == :cycle, do: DateTime.add(fixture.window.reset_at, 3600), else: fixture.window.reset_at
      identity = identity |> change(metadata: Map.put(identity.metadata, "credential_epoch", epoch)) |> Repo.update!()
      Repo.delete!(Repo.reload!(fixture.window))
      record_cycle!(identity, reset_at, epoch)
      FakeUpstream.set_mode(fixture.fake, {:path_json, fixture.routes})

      assert {:ok, _, _} = SavedResetRedemption.ensure_manual_available(fixture.assignment)
      assert {:ok, %{applied?: true}} = SavedResetRedemption.redeem(fixture.assignment)
      context = Repo.reload!(identity).metadata["saved_reset_redemption"]["manual_replacement"]
      assert context["receipt"] == old_context["receipt"]
      assert context["credential_epoch"] == epoch
      assert context["reset_at"] == iso(reset_at)
      refute context["window_id"] == old_context["window_id"]
      assert FakeUpstream.physical_counts(fixture.fake).consume == 1
    end
  end

  test "an old provider scope fingerprint cannot authorize a new manual claim" do
    fixture = fixture!()
    fixture.identity |> change(chatgpt_account_id: "synthetic-replaced-account") |> Repo.update!()
    assert {:error, %{code: :saved_reset_redemption_in_progress}} = SavedResetRedemption.ensure_manual_available(fixture.assignment)
    assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(fixture.assignment)
    assert FakeUpstream.physical_counts(fixture.fake).consume == 0
  end

  for lost <- [:anchor, :epoch, :scope, :window, :context] do
    test "losing #{lost} after a manual claim cancels before the irreversible POST" do
      fixture = fixture!()
      {task, gate_pid, release_ref} = gated_claim!(fixture)
      lose_proof!(fixture, unquote(lost))
      send(gate_pid, {:fake_upstream_release_gate, release_ref})

      assert {:ok, %{status: :noop, applied?: false}} = Task.await(task, 15_000)
      receipt = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
      assert receipt["phase"] == "manual_replacement_not_applied"
      assert receipt["provider_replay"]["provider_dispatches"] == 0
      assert RedemptionLifecycle.gateway_auto_latch(receipt, DateTime.utc_now()) == :blocked_awaiting_quota
      assert RedemptionLifecycle.gateway_auto_sibling_fence(receipt, DateTime.utc_now()) == :blocked_awaiting_quota
      assert FakeUpstream.physical_counts(fixture.fake).consume == 0
    end
  end

  test "overlapping explicit requests accept one claim and send one consume" do
    fixture = fixture!()
    {task, gate_pid, release_ref} = gated_claim!(fixture)
    assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(fixture.assignment)
    send(gate_pid, {:fake_upstream_release_gate, release_ref})
    assert {:ok, %{applied?: true}} = Task.await(task, 15_000)
    assert FakeUpstream.physical_counts(fixture.fake).consume == 1
  end

  test "two pools racing on independent database connections reserve only one consume for the identity" do
    fixture = fixture!(true)

    second =
      CodexPooler.UnboxedFixture.run_unboxed(fn ->
        pool = pool_fixture(%{slug: fixture.slug <> "-second"})
        {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, fixture.identity, %{})
        {:ok, assignment} = PoolAssignments.activate_pool_assignment(assignment)
        assignment
      end)

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity, where: identity.id == ^fixture.identity.id, lock: "FOR UPDATE")
            send(parent, {:holding_identity, backend_pid!()})

            receive do
              :release -> :ok
            after
              15_000 -> flunk("identity lock release missing")
            end
          end)
        end)
      end)

    assert_receive {:holding_identity, holder_backend}, 15_000

    racers =
      for assignment <- [fixture.assignment, second] do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.checkout(fn ->
              send(parent, {:claim_backend, backend_pid!()})
              SavedResetRedemption.redeem(assignment)
            end)
          end)
        end)
      end

    assert_receive {:claim_backend, first_backend}, 15_000
    assert_receive {:claim_backend, second_backend}, 15_000
    assert length(Enum.uniq([holder_backend, first_backend, second_backend])) == 3
    deadline = System.monotonic_time(:millisecond) + 15_000
    first_blockers = await_blocker!(first_backend, [holder_backend, second_backend], deadline)
    second_blockers = await_blocker!(second_backend, [holder_backend, first_backend], deadline)
    assert holder_backend in first_blockers or holder_backend in second_blockers
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 15_000)
    results = Enum.map(racers, &Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, %{applied?: true}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :redemption_in_progress})) == 1
    assert FakeUpstream.physical_counts(fixture.fake).consume == 1
  end

  defp backend_pid! do
    %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp await_blocker!(waiter, expected_blockers, deadline) do
    blockers =
      CodexPooler.UnboxedFixture.run_unboxed(fn ->
        %{rows: [[pids]]} = SQL.query!(Repo, "SELECT pg_blocking_pids($1)", [waiter])
        pids
      end)

    if Enum.any?(blockers, &(&1 in expected_blockers)) do
      blockers
    else
      if System.monotonic_time(:millisecond) >= deadline do
        active = CodexPooler.UnboxedFixture.run_unboxed(fn -> SQL.query!(Repo, "SELECT pid, wait_event, pg_blocking_pids(pid) FROM pg_stat_activity WHERE datname = current_database()", []).rows end)
        flunk("claim did not wait for the identity lock: #{inspect({waiter, expected_blockers, blockers, active})}")
      end

      await_blocker!(waiter, expected_blockers, deadline)
    end
  end

  test "a crashed zero-dispatch replacement revalidates its persisted cycle proof during recovery" do
    fixture = fixture!()
    {task, gate_pid, release_ref} = gated_claim!(fixture)
    Task.shutdown(task, :brutal_kill)
    send(gate_pid, {:fake_upstream_release_gate, release_ref})
    FakeUpstream.set_mode(fixture.fake, {:path_json, fixture.routes})
    lose_proof!(fixture, :anchor)
    receipt = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
    assert receipt["provider_replay"]["provider_dispatches"] == 0
    assert is_map(receipt["manual_replacement"])
    assert RedemptionLifecycle.can_transition?(receipt, "manual_replacement_not_applied", receipt["generation"], receipt["attempt_id"])
    refute RedemptionLifecycle.can_transition?(put_in(receipt, ["provider_replay", "provider_dispatches"], 1), "manual_replacement_not_applied", receipt["generation"], receipt["attempt_id"])
    refute RedemptionLifecycle.can_transition?(receipt, "manual_replacement_not_applied", receipt["generation"] + 1, receipt["attempt_id"])
    at = DateTime.add(DateTime.utc_now(), 90)

    assert {:ok, %{status: :noop, code: "saved_reset_manual_proof_unavailable"}} = SavedResetRedemption.resume_stale_consuming(fixture.assignment, fixture.identity.id, receipt["attempt_id"], receipt["generation"], now: at, clock: fn -> at end)
    assert Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]["phase"] == "manual_replacement_not_applied"
    assert FakeUpstream.physical_counts(fixture.fake).consume == 0
  end

  test "an ambiguous replacement retains its latch and never repeats the POST after proof loss" do
    fixture = fixture!()
    FakeUpstream.set_mode(fixture.fake, {:path_json, Map.put(fixture.routes, "/backend-api/wham/rate-limit-reset-credits/consume", :close_before_headers)})
    assert {:error, :saved_reset_consume_outcome_ambiguous} = SavedResetRedemption.redeem(fixture.assignment)
    receipt = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
    lose_proof!(fixture, :anchor)
    FakeUpstream.set_mode(fixture.fake, {:path_json, fixture.routes})
    at = DateTime.add(DateTime.utc_now(), 90)

    assert {:ok, %{status: :noop, code: "saved_reset_manual_proof_unavailable"}} = SavedResetRedemption.resume_stale_consuming(fixture.assignment, fixture.identity.id, receipt["attempt_id"], receipt["generation"], now: at, clock: fn -> at end)
    current = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
    assert current["phase"] == "consuming"
    assert current["provider_replay"]["provider_dispatches"] == 1
    assert FakeUpstream.physical_counts(fixture.fake).consume == 1
  end

  for dispatches <- [0, 1] do
    test "removing the replacement proof during recovery cannot enable a later retry after #{dispatches} dispatches" do
      fixture = fixture!()

      if unquote(dispatches) == 0 do
        {task, gate_pid, ref} = gated_claim!(fixture)
        Task.shutdown(task, :brutal_kill)
        send(gate_pid, {:fake_upstream_release_gate, ref})
      else
        FakeUpstream.set_mode(fixture.fake, {:path_json, Map.put(fixture.routes, "/backend-api/wham/rate-limit-reset-credits/consume", :close_before_headers)})
        assert {:error, :saved_reset_consume_outcome_ambiguous} = SavedResetRedemption.redeem(fixture.assignment)
      end

      receipt = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
      at = DateTime.add(DateTime.utc_now(), 90)
      ref = make_ref()
      {200, credits} = fixture.routes["/backend-api/wham/rate-limit-reset-credits"]
      gate = FakeUpstream.gated_json_headers(credits, notify: self(), release_ref: ref)
      FakeUpstream.set_mode(fixture.fake, {:path_json, Map.put(fixture.routes, "/backend-api/wham/rate-limit-reset-credits", gate)})
      task = Task.async(fn -> SavedResetRedemption.resume_stale_consuming(fixture.assignment, fixture.identity.id, receipt["attempt_id"], receipt["generation"], now: at, clock: fn -> at end) end)
      assert_receive {:fake_upstream_gate, :before_headers, gate_pid, ^ref}, 15_000
      lose_proof!(fixture, :context)
      lose_proof!(fixture, :anchor)
      send(gate_pid, {:fake_upstream_release_gate, ref})
      assert {:ok, %{status: :noop}} = Task.await(task, 15_000)
      FakeUpstream.set_mode(fixture.fake, {:path_json, fixture.routes})
      assert {:ok, %{status: :noop}} = SavedResetRedemption.resume_stale_consuming(fixture.assignment, fixture.identity.id, receipt["attempt_id"], receipt["generation"], now: at, clock: fn -> at end)
      current = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
      assert is_map(current["manual_replacement"])
      assert FakeUpstream.physical_counts(fixture.fake).consume == unquote(dispatches)
      assert RedemptionLifecycle.gateway_auto_latch(current, at) == :blocked_awaiting_quota
    end
  end

  defp gated_claim!(fixture) do
    release_ref = make_ref()
    {200, credits} = fixture.routes["/backend-api/wham/rate-limit-reset-credits"]
    gate = FakeUpstream.gated_json_headers(credits, notify: self(), release_ref: release_ref)
    FakeUpstream.set_mode(fixture.fake, {:path_json, Map.put(fixture.routes, "/backend-api/wham/rate-limit-reset-credits", gate)})
    task = Task.async(fn -> SavedResetRedemption.redeem(fixture.assignment) end)
    assert_receive {:fake_upstream_gate, :before_headers, gate_pid, ^release_ref}, 15_000
    {task, gate_pid, release_ref}
  end

  defp lose_proof!(fixture, lost) do
    identity = Repo.reload!(fixture.identity)
    window = Repo.reload!(fixture.window)

    case lost do
      :anchor -> window |> change(metadata: Map.delete(window.metadata, "__quota_cycle_confirmation_v1")) |> Repo.update!()
      :epoch -> identity |> change(metadata: Map.put(identity.metadata, "credential_epoch", 16)) |> Repo.update!()
      :scope -> identity |> change(chatgpt_account_id: "synthetic-replaced-account") |> Repo.update!()
      :window -> Repo.delete!(window)
      :context -> identity |> change(metadata: update_in(identity.metadata, ["saved_reset_redemption"], &Map.delete(&1, "manual_replacement"))) |> Repo.update!()
    end
  end

  defp invalidate!(fixture, invalid) do
    identity = fixture.identity
    receipt = identity.metadata["saved_reset_redemption"]
    window = fixture.window

    receipt = invalid_receipt(invalid, receipt, window, fixture)

    identity |> change(metadata: Map.put(identity.metadata, "saved_reset_redemption", receipt)) |> Repo.update!()

    attrs = invalid_window(invalid, window, fixture)

    window |> change(attrs) |> Repo.update!()
    fixture
  end

  defp invalid_receipt(:missing_binding, receipt, _window, _fixture), do: Map.delete(receipt, "included_window_descriptors")
  defp invalid_receipt(:nonempty_binding, receipt, _window, _fixture), do: Map.put(receipt, "included_window_descriptors", [%{"window_kind" => "secondary", "window_minutes" => 10_080}])
  defp invalid_receipt(:unapplied, receipt, _window, _fixture), do: put_in(receipt, ["result", "applied"], false)
  defp invalid_receipt(:unknown_code, receipt, _window, _fixture), do: put_in(receipt, ["result", "code"], "unknown")
  defp invalid_receipt(:inflight, receipt, _window, _fixture), do: Map.put(receipt, "phase", "consuming")
  defp invalid_receipt(:unknown_phase, receipt, _window, _fixture), do: Map.put(receipt, "phase", "unknown")
  defp invalid_receipt(:bad_attempt, receipt, _window, _fixture), do: Map.put(receipt, "attempt_id", "invalid")
  defp invalid_receipt(:bad_generation, receipt, _window, _fixture), do: Map.put(receipt, "generation", 0)
  defp invalid_receipt(:no_dispatch, receipt, _window, _fixture), do: put_in(receipt, ["provider_replay", "provider_dispatches"], 0)
  defp invalid_receipt(:too_many_dispatches, receipt, _window, _fixture), do: put_in(receipt, ["provider_replay", "provider_dispatches"], 7)
  defp invalid_receipt(:bad_replay, receipt, _window, _fixture), do: Map.put(receipt, "provider_replay", %{})
  defp invalid_receipt(:future_finish, receipt, _window, fixture), do: Map.put(receipt, "finished_at", iso(DateTime.add(fixture.now, 30)))
  defp invalid_receipt(:reversed_clocks, receipt, _window, _fixture), do: Map.put(receipt, "started_at", receipt["deadline_at"])
  defp invalid_receipt(:same_cycle, receipt, window, _fixture), do: receipt_clocks(receipt, DateTime.add(window.reset_at, -604_800))
  defp invalid_receipt(:near_cycle, receipt, window, _fixture), do: receipt_clocks(receipt, DateTime.add(window.reset_at, -604_805))
  defp invalid_receipt(:cooldown, receipt, _window, fixture), do: receipt |> Map.put("started_at", iso(DateTime.add(fixture.now, -1201))) |> Map.put("consumed_at", iso(DateTime.add(fixture.now, -1200))) |> Map.put("deadline_at", iso(DateTime.add(fixture.now, -300))) |> Map.put("finished_at", iso(DateTime.add(fixture.now, -200)))
  defp invalid_receipt(_, receipt, _window, _fixture), do: receipt
  defp invalid_window(:floating, window, _fixture), do: %{metadata: Map.put(window.metadata, "reset_state", "floating")}
  defp invalid_window(:stale, _window, fixture), do: %{observed_at: DateTime.add(fixture.now, -7200)}
  defp invalid_window(:future_observation, _window, fixture), do: %{observed_at: DateTime.add(fixture.now, 30)}
  defp invalid_window(:future_provider, window, fixture), do: %{metadata: put_in(window.metadata, ["__quota_cycle_confirmation_v1", "provider_observed_at"], iso(DateTime.add(fixture.now, 30)))}
  defp invalid_window(:stale_provider, window, fixture), do: %{metadata: put_in(window.metadata, ["__quota_cycle_confirmation_v1", "provider_observed_at"], iso(DateTime.add(fixture.now, -7200)))}
  defp invalid_window(:future_confirmation, window, fixture), do: %{metadata: put_in(window.metadata, ["__quota_cycle_confirmation_v1", "confirmed_at"], iso(DateTime.add(fixture.now, 30)))}
  defp invalid_window(:malformed_marker, window, _fixture), do: %{metadata: Map.put(window.metadata, "__quota_cycle_confirmation_v1", %{})}
  defp invalid_window(:wrong_epoch, window, _fixture), do: %{metadata: Map.put(window.metadata, "credential_epoch", 14)}
  defp invalid_window(:missing_epoch, window, _fixture), do: %{metadata: Map.delete(window.metadata, "credential_epoch")}
  defp invalid_window(:monthly, _window, _fixture), do: %{window_kind: "primary", window_minutes: 43_200}
  defp invalid_window(:wrong_source, _window, _fixture), do: %{source: "codex_rate_limit_event"}
  defp invalid_window(:wrong_scope, _window, _fixture), do: %{quota_scope: "model"}
  defp invalid_window(:moving_reset, window, _fixture), do: %{reset_at: DateTime.add(window.reset_at, 60)}
  defp invalid_window(_, _window, _fixture), do: %{}

  defp receipt_clocks(receipt, consumed_at) do
    receipt |> Map.put("started_at", iso(DateTime.add(consumed_at, -1))) |> Map.put("consumed_at", iso(consumed_at)) |> Map.put("deadline_at", iso(DateTime.add(consumed_at, 900))) |> Map.put("finished_at", iso(DateTime.add(consumed_at, 960)))
  end

  defp record_cycle!(identity, reset_at, epoch) do
    now = DateTime.utc_now()

    for offset <- [-600, -400, -1] do
      at = DateTime.add(now, offset)

      assert {:ok, _} =
               Windows.record_evidence(
                 identity,
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: at,
                   last_sync_at: at,
                   reset_at: reset_at,
                   used_percent: Decimal.new(100),
                   metadata: %{"credential_epoch" => epoch, "reset_after_seconds" => DateTime.diff(reset_at, at)}
                 },
                 at
               )
    end
  end

  defp fixture!(committed? \\ false) do
    name = String.to_atom("historical_reset_#{System.unique_integer([:positive, :monotonic])}")
    slug = "historical-reset-#{Ecto.UUID.generate()}"
    account = "synthetic-#{Ecto.UUID.generate()}"

    if committed? do
      CodexPooler.UnboxedFixture.register_unboxed_cleanup!(fn ->
        pool_ids = Repo.all(from pool in CodexPooler.Pools.Pool, where: pool.slug in ^[slug, slug <> "-second"], select: pool.id)
        delete_committed_pools!(pool_ids)
        Repo.delete_all(from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity, where: identity.chatgpt_account_id == ^account)
      end)
    end

    on_exit(fn ->
      case Process.whereis(name) do
        nil -> :ok
        pid -> FakeUpstream.stop(%FakeUpstream{supervisor: pid})
      end
    end)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    routes =
      ProviderCreditsFixtures.usage_routes(%{"plan_type" => "synthetic", "rate_limit_reset_credits" => %{"available_count" => 1}})
      |> Map.put("/backend-api/wham/rate-limit-reset-credits", {200, %{"available_count" => 2, "credits" => [%{"id" => "synthetic-reset-a", "status" => "available"}, %{"id" => "synthetic-reset-b", "status" => "available"}]}})
      |> Map.put("/backend-api/wham/rate-limit-reset-credits/consume", {200, %{"code" => "reset"}})

    {:ok, fake} = FakeUpstream.start_link({:path_json, routes}, supervisor_name: name)

    runner = if committed?, do: &CodexPooler.UnboxedFixture.run_unboxed/1, else: fn fun -> fun.() end

    runner.(fn ->
      %{assignment: assignment, identity: identity} =
        active_upstream_assignment_fixture(pool_fixture(%{slug: slug}), %{
          chatgpt_account_id: account,
          metadata: %{
            "base_url" => FakeUpstream.url(fake),
            "usage_base_url" => FakeUpstream.url(fake),
            "credential_epoch" => 15,
            "saved_resets" => %{"status" => "reported", "available_count" => 2, "source" => "codex_usage_api", "path_style" => "chatgpt_api", "usage_path" => "/backend-api/wham/usage", "observed_at" => DateTime.to_iso8601(now)}
          }
        })

      consumed_at = DateTime.add(now, -172_800)

      redemption = %{
        "phase" => "expired",
        "status" => "failed",
        "attempt_id" => Ecto.UUID.generate(),
        "generation" => 3,
        "included_window_descriptors" => [],
        "started_at" => iso(DateTime.add(consumed_at, -1)),
        "consumed_at" => iso(consumed_at),
        "deadline_at" => iso(DateTime.add(consumed_at, 900)),
        "finished_at" => iso(DateTime.add(consumed_at, 960)),
        "result" => %{"code" => "reset", "applied" => true},
        "provider_replay" => %{"version" => 1, "provider_dispatches" => 1, "endpoint_family" => "chatgpt_api", "scope_fingerprint" => CreditLocator.scope_fingerprint("chatgpt_api", FakeUpstream.url(fake) <> "/backend-api/wham/rate-limit-reset-credits/consume", identity.chatgpt_account_id || "")}
      }

      identity = identity |> change(metadata: Map.put(identity.metadata, "saved_reset_redemption", redemption)) |> Repo.update!()
      reset_at = DateTime.add(now, 604_800 - 86_400)

      for offset <- [-600, -400, -1] do
        at = DateTime.add(now, offset)

        assert {:ok, _} =
                 Windows.record_evidence(
                   identity,
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     observed_at: at,
                     last_sync_at: at,
                     reset_at: reset_at,
                     used_percent: Decimal.new(100),
                     metadata: %{"credential_epoch" => 15, "reset_after_seconds" => DateTime.diff(reset_at, at)}
                   },
                   at
                 )
      end

      now = DateTime.utc_now()
      [window] = Windows.list_evidence(identity)
      assert CycleConfirmation.selector_valid?(window, now)
      %{identity: identity, assignment: assignment, fake: fake, now: now, window: window, routes: routes, slug: slug}
    end)
  end

  defp iso(datetime), do: DateTime.to_iso8601(datetime)
end
