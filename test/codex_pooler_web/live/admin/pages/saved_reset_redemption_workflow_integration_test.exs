defmodule CodexPoolerWeb.Admin.SavedResetRedemptionWorkflowIntegrationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Repo
  alias CodexPooler.SavedResetConfirmationFixtures
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets.Convergence
  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.LiveViewTest.ClientProxy

  @consume "/api/codex/rate-limit-reset-credits/consume"
  @usage "/api/codex/usage"
  @worker "CodexPooler.Jobs.SavedResetRedemptionWorker"
  @detection_timeout 15_000
  @week 604_800

  setup :register_and_log_in_user

  setup do
    # Cleanup is registered before acquisition. This unlinked tracker outlives
    # the test process, unlike ExUnit-supervised children stopped before on_exit.
    name = String.to_atom("reset_workflow_resources_#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_registered(name) end)
    {:ok, resources} = Agent.start(fn -> [] end, name: name)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    Process.unlink(task_supervisor)
    Agent.update(resources, &[{:task_supervisor, task_supervisor} | &1])
    %{resources: resources, task_supervisor: task_supervisor}
  end

  test "view teardown waits for its deferred cockpit audit query", context do
    %{identity: identity} = upstream_assignment_fixture(pool_fixture())
    {list, cockpit} = open_views(context, identity)
    render_async(list, @detection_timeout)
    render_async(cockpit, @detection_timeout)
    tag = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(tag) end)
    :ok = :telemetry.attach(tag, [:codex_pooler, :repo, :query], &__MODULE__.hold_cockpit_audit/4, %{context: context, parent: self(), view: cockpit.pid, tag: tag})
    render_click(cockpit, "refresh_data", %{})
    assert_receive {^tag, :audit_held, actor}, @detection_timeout
    monitor = Process.monitor(actor)
    stopper = Task.async(fn -> stop_view(cockpit) end)

    try do
      assert await_async_shutdown(cockpit.pid, System.monotonic_time(:millisecond) + @detection_timeout) == :waiting
      assert Task.yield(stopper, 0) == nil
    after
      :telemetry.detach(tag)
      send(actor, {:release_cockpit_audit, tag})
      Task.await(stopper, @detection_timeout)
    end

    assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, @detection_timeout
    refute Process.alive?(cockpit.pid)
    finish(context, [list, cockpit], [], "async_view_teardown")
  end

  @doc false
  @spec hold_cockpit_audit([atom()], map(), map(), map()) :: :ok
  def hold_cockpit_audit(_event, _measurements, metadata, %{context: context, parent: parent, view: view, tag: tag}) do
    query = to_string(metadata[:query])

    if view in Process.get(:"$callers", []) and String.contains?(query, "audit_events") and String.contains?(query, "count(") do
      remember(context, {:gate, self(), :release_cockpit_audit, tag})
      send(parent, {tag, :audit_held, self()})

      receive do
        {:release_cockpit_audit, ^tag} -> :ok
      after
        @detection_timeout -> raise "cockpit audit barrier was not released"
      end
    end

    :ok
  end

  defp await_async_shutdown(view, deadline) do
    case Process.info(view, :current_stacktrace) do
      nil ->
        :stopped

      {:current_stacktrace, stack} ->
        poll_async_shutdown(view, stack, deadline)
    end
  end

  defp poll_async_shutdown(view, stack, deadline) do
    if Enum.any?(stack, fn {module, function, _, _} -> module == Phoenix.LiveView.Channel and String.contains?(Atom.to_string(function), "await_asyncs") end) do
      :waiting
    else
      assert System.monotonic_time(:millisecond) < deadline, "view did not enter async shutdown"

      receive do
      after
        1 -> await_async_shutdown(view, deadline)
      end
    end
  end

  test "one_manual_consume_open_views_confirm", context do
    consume_ref = make_ref()
    usage_ref = make_ref()

    fake =
      fake!(
        context,
        {:path_json,
         %{
           @consume => FakeUpstream.barrier_json_response(%{"code" => "reset"}, notify: self(), release_ref: consume_ref),
           @usage => FakeUpstream.gated_json_headers(usage(0, DateTime.utc_now()), notify: self(), release_ref: usage_ref)
         }}
      )

    fixture = manual_fixture(context, fake)
    %{identity: identity, assignment: assignment} = fixture
    [before_reset] = QuotaWindows.list_evidence(identity)
    assert {:ok, _} = QuotaWindows.record_evidence(identity, %{weekly("100", before_reset.observed_at, before_reset.reset_at) | source: "codex_rate_limit_event"}, before_reset.observed_at)
    {list, cockpit} = open_views(context, identity)
    render_click(list, "open_saved_reset_policy", %{"id" => identity.id})
    render_click(list, "open_quota_observations", %{})
    render_click(cockpit, "open_quota_observations", %{})
    draft = %{"keep_credits" => "7", "min_blocked_minutes" => "29", "trigger_mode" => "threshold", "quota_threshold_percent" => "86"}
    render_change(list, "validate_saved_reset_policy", %{"saved_reset_policy" => draft})
    form = :sys.get_state(list.pid).socket.assigns.saved_reset_policy_form
    job = submit_one(list, fixture)
    assert job.args["trigger_kind"] == "admin_manual"
    assert job.args["manual_request_target"] == %{"upstream_identity_id" => identity.id, "pool_id" => fixture.pool.id}
    refresh_views([list, cockpit], identity)
    assert has_element?(list, heading(:bank, identity), "Request accepted")
    assert has_element?(cockpit, heading(:cockpit, identity), "Request accepted")
    render_click(list, "redeem_saved_reset", target(fixture))
    assert [same] = owned_jobs(assignment)
    assert same.id == job.id

    drain = drain_task(context)
    monitor = CodexPooler.TestProcess.monitor_flushed(drain.pid)
    assert_receive {:fake_upstream_timeout_barrier, :before_headers, consume_pid, ^consume_ref}, @detection_timeout
    assert Repo.reload!(identity).metadata["saved_reset_redemption"]["phase"] == "consuming"
    assert Repo.get!(Oban.Job, job.id).state == "executing"
    assert_counts(fake, 1)
    remember(context, {:gate, consume_pid, :fake_upstream_release_timeout, consume_ref})
    send(consume_pid, {:fake_upstream_release_timeout, consume_ref})
    assert_receive {:fake_upstream_gate, :before_headers, usage_pid, ^usage_ref}, @detection_timeout
    remember(context, {:gate, usage_pid, :fake_upstream_release_gate, usage_ref})
    send(usage_pid, {:fake_upstream_release_gate, usage_ref})
    assert %{success: 1, failure: 0} = Task.await(drain, @detection_timeout)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, @detection_timeout
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    assert %DateTime{} = Repo.get!(Oban.Job, job.id).completed_at
    applied = Repo.reload!(identity)
    real_claim = applied.metadata["saved_reset_redemption"]
    assert real_claim["phase"] == "consumed_pending_probe"
    assert real_claim["generation"] == 1
    assert real_claim["provider_replay"]["provider_dispatches"] == 1
    assert real_claim["included_window_descriptors"] == [%{"window_kind" => "secondary", "window_minutes" => 10_080}]
    assert %{"code" => "reset", "applied" => true} = real_claim["result"]
    assert applied.metadata["saved_resets"]["available_count"] == 0
    refresh_views([list, cockpit], identity)
    assert_operation([{:bank, list}, {:cockpit, cockpit}], identity, "applied", "pending")

    # The completed job adds nothing beside the latest receipt, so only the receipt reads.
    for {surface, view} <- [{:bank, list}, {:cockpit, cockpit}] do
      assert has_element?(view, heading(surface, identity), "Reset applied — verifying quota")
      assert has_element?(view, receipt(surface, identity) <> " [data-role='saved-reset-latest']", "Waiting for a usage report to confirm the new quota.")
      refute has_element?(view, receipt(surface, identity) <> " [data-role='saved-reset-request']")
    end

    assert :sys.get_state(list.pid).socket.assigns.quota_observations_open?
    assert :sys.get_state(list.pid).socket.assigns.saved_reset_policy_form === form
    assert has_element?(list, "#saved-reset-policy-dialog[open]")
    record("journey", "completed_job_pending_quota", %{job_completed: true, generation: 1, phase: real_claim["phase"], inventory_delta: -1, physical_counts: FakeUpstream.physical_counts(fake)})

    # Advance only this fixture's timeline, preserving the actual claimed
    # generation, attempt, result and descriptors. This is synthetic elapsed
    # time, not measured provider latency or a fabricated confirmed phase.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    candidate_at = DateTime.add(now, -180, :second)
    consumed_at = DateTime.add(candidate_at, -60, :second)
    canonical_at = DateTime.add(candidate_at, -300, :second)
    advance_fixture(applied, real_claim, consumed_at, canonical_at, candidate_at)
    exhausted_at = DateTime.add(consumed_at, -30, :second)
    assert {:ok, old_event} = QuotaWindows.record_evidence(identity, %{weekly("100", exhausted_at, DateTime.add(canonical_at, 5, :day)) | source: "codex_rate_limit_event"}, exhausted_at)
    below = DateTime.add(candidate_at, 179, :second)
    fetch_usage(context, fixture, below, usage(0, below))
    assert {:ok, :unchanged} = Convergence.converge(identity.id, below, "reconciliation")
    assert Repo.reload!(identity).metadata["saved_reset_redemption"]["phase"] == "consumed_pending_probe"
    refresh_views([list, cockpit], identity)
    window = Enum.find(QuotaWindows.list_evidence(identity), &(&1.source == "codex_usage_api"))
    assert {:ok, candidate} = EvidenceStore.parse_candidate(window.metadata)
    assert EvidenceStore.candidate_provider_status_safe?(window.metadata)
    assert candidate.observed_at == candidate_at
    assert window.observed_at == canonical_at
    assert DateTime.compare(candidate.observed_at, window.observed_at) == :gt
    current = :sys.get_state(list.pid).socket.assigns.editing_saved_reset_policy
    assert current.saved_reset_confirmation.challenged_evidence_state == :candidate_progressing
    assert current.saved_reset_operation.last_checked_at != nil
    assert_operation([{:bank, list}, {:cockpit, cockpit}], identity, "applied", "candidate")
    assert render(list) =~ "Last verified quota"
    assert render(list) =~ "New quota report awaiting verification"
    assert :sys.get_state(list.pid).socket.assigns.saved_reset_policy_form === form

    fetch_usage(context, fixture, now, usage(0, now))
    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity.id, now, "reconciliation")
    confirmed = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert Map.take(confirmed, ["attempt_id", "generation", "result", "included_window_descriptors"]) == Map.take(real_claim, ["attempt_id", "generation", "result", "included_window_descriptors"])
    refresh_views([list, cockpit], identity)
    assert_operation([{:bank, list}, {:cockpit, cockpit}], identity, "applied", "quota_confirmed")
    assert has_element?(list, "#saved-reset-policy-dialog[open]")
    assert :sys.get_state(list.pid).socket.assigns.quota_observations_open?
    assert :sys.get_state(cockpit.pid).socket.assigns.quota_observations_open?
    assert :sys.get_state(list.pid).socket.assigns.saved_reset_policy_form === form
    assert :sys.get_state(list.pid).socket.assigns.editing_saved_reset_policy.saved_reset_operation.serving_readiness.routing_ready_now?
    assert has_element?(list, "#upstream-account-#{identity.id}-limit-weekly-progress", "100%")
    assert Repo.get!(AccountQuotaWindow, old_event.id).used_percent == Decimal.new("100.000")
    assert DateTime.diff(now, old_event.observed_at, :second) < 900
    %{api_key: api_key} = active_api_key_fixture(fixture.pool)
    input = filter_input(fixture.pool, api_key, [fixture])
    assert {:ok, [{routable_assignment, _routable_identity}], _options, _state} = route(input)
    assert routable_assignment.id == assignment.id

    counts = FakeUpstream.physical_counts(fake)
    render_hook(list, "set_live_updates", %{"paused" => true})
    refresh_views([list, cockpit], identity)
    assert :sys.get_state(list.pid).socket.assigns.live_updates_paused?
    assert FakeUpstream.physical_counts(fake) == counts
    stop_view(list)
    stop_view(cockpit)
    {remounted, second} = open_views(context, identity)
    render_click(remounted, "open_saved_reset_policy", %{"id" => identity.id})
    assert_operation([{:bank, remounted}, {:cockpit, second}], identity, "applied", "quota_confirmed")
    render_click(remounted, "redeem_saved_reset", target(fixture))
    refresh_views([remounted, second], identity)
    assert FakeUpstream.physical_counts(fake) == counts
    assert_counts(fake, 1)
    assert [retained] = owned_jobs(assignment)
    assert retained.id == job.id
    record("journey", "one_manual_consume_open_views_confirm", %{guard_below_seconds: 179, guard_accepted_seconds: 180, open_views_confirmed: 2, remounted_views_confirmed: 2, refresh_extra_calls: 0, duplicate_extra_consumes: 0, generation: confirmed["generation"], physical_counts: counts, synthetic_clock: true})
    finish(context, [remounted, second], [fake], "manual")
  end

  test "discarded enqueue acknowledgement remount resumes the same persisted request", context do
    fake = fake!(context, {:path_json, %{@consume => {200, %{"code" => "reset"}}, @usage => {200, usage(0, DateTime.utc_now())}}})
    fixture = manual_fixture(context, fake)
    {list, cockpit} = open_views(context, fixture.identity)
    render_click(list, "open_saved_reset_policy", %{"id" => fixture.identity.id})
    job = submit_one(list, fixture)
    # Discard the connected view immediately after submission; neither its
    # rendered acceptance nor its browser state is used by the replacement.
    stop_view(list)
    {:ok, replacement, _} = live(context.conn, ~p"/admin/upstreams")
    remember(context, {:view, replacement})
    render_click(replacement, "open_saved_reset_policy", %{"id" => fixture.identity.id})
    assert has_element?(replacement, heading(:bank, fixture.identity), "Request accepted")
    render_click(replacement, "redeem_saved_reset", target(fixture))
    assert [retained] = owned_jobs(fixture.assignment)
    assert retained.id == job.id
    assert_counts(fake, 0)
    assert %{success: 1} = drain_queue()
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    refresh_views([replacement, cockpit], fixture.identity)
    assert_operation([{:bank, replacement}, {:cockpit, cockpit}], fixture.identity, "applied", "pending")
    render_click(replacement, "redeem_saved_reset", target(fixture))
    refresh_views([replacement, cockpit], fixture.identity)
    assert_counts(fake, 1)
    assert [same] = owned_jobs(fixture.assignment)
    assert same.id == job.id
    record("journey", "discarded_enqueue_acknowledgement", %{same_persisted_job: true, remounted_request_accepted: true, extra_consumes: 0, physical_counts: FakeUpstream.physical_counts(fake)})
    finish(context, [replacement, cockpit], [fake], "lost_browser_ack")
  end

  for {code, outcome, headline, guidance} <- [
        {"lost_reply", "unknown", "Reset outcome not confirmed", "Don't redeem again until this resolves."},
        {"no_credit", "not_applied", "No saved reset was available", "The provider had no saved reset to apply."},
        {"nothing_to_reset", "not_applied", "Nothing needed resetting", "The provider found no exhausted quota to reset."}
      ] do
    test "lost_provider_reply_and_definitive_noop #{code}", context do
      code = unquote(code)
      consume = if code == "lost_reply", do: FakeUpstream.close_before_headers(), else: {200, %{"code" => code}}
      fake = fake!(context, {:path_json, %{@consume => consume, @usage => {200, usage(1, DateTime.utc_now())}}})
      fixture = manual_fixture(context, fake)
      {list, cockpit} = open_views(context, fixture.identity)
      render_click(list, "open_saved_reset_policy", %{"id" => fixture.identity.id})
      job = submit_one(list, fixture)
      {result, fault_log} = ExUnit.CaptureLog.with_log(fn -> drain_queue() end)
      assert fault_log =~ "oban job discarded"
      stored_job = Repo.get!(Oban.Job, job.id)

      if code == "lost_reply" do
        assert fault_log =~ "saved_reset_consume_outcome_ambiguous"
        assert result.discard == 1
        assert stored_job.state == "discarded"
        redemption = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
        assert redemption["phase"] == "consuming"
        assert redemption["provider_replay"]["provider_dispatches"] == 1
        assert redemption["result"] == nil
      else
        assert result.discard == 1
        assert stored_job.state == "discarded"
        assert %{"code" => ^code, "applied" => false} = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]["result"]
      end

      refresh_views([list, cockpit], fixture.identity)

      for {surface, view} <- [{:bank, list}, {:cockpit, cockpit}] do
        assert has_element?(view, receipt(surface, fixture.identity) <> "[data-provider-outcome='#{unquote(outcome)}']", unquote(guidance))
        assert has_element?(view, heading(surface, fixture.identity), unquote(headline))
        refute has_element?(view, receipt(surface, fixture.identity) <> " [data-role='saved-reset-consumed-at']")
        # The discarded job says it did not complete and points at the receipt instead of denying a result.
        request = receipt(surface, fixture.identity) <> " [data-role='saved-reset-request']"
        assert has_element?(view, request, "Request did not complete")
        assert has_element?(view, request, "Check the latest reset before acting.")
      end

      counts = FakeUpstream.physical_counts(fake)
      render_click(list, "redeem_saved_reset", target(fixture))
      refresh_views([list, cockpit], fixture.identity)
      assert FakeUpstream.physical_counts(fake) == counts
      expected_bank = if code == "no_credit", do: 0, else: 1
      assert Repo.reload!(fixture.identity).metadata["saved_resets"]["available_count"] == expected_bank
      assert_counts(fake, 1)
      record("failure", code, %{provider_outcome: unquote(outcome), acknowledged_job_state: stored_job.state, physical_counts: counts, refresh_extra_calls: 0, inventory_delta: expected_bank - 1, safe_retry_not_claimed: true, expected_discard_log_observed: true})
      finish(context, [list, cockpit], [fake], "manual_" <> code)
    end
  end

  test "ranked_blocked_recovery_receipt", context do
    pool = pool_fixture(%{created_by_user_id: context.scope.user.id})
    %{api_key: api_key} = active_api_key_fixture(pool)
    later_fake = fake!(context, {:path_json, %{@consume => {200, %{"code" => "reset"}}, @usage => {200, ranked_usage()}}})
    earlier_fake = fake!(context, {:path_json, %{@consume => {200, %{"code" => "reset"}}, @usage => {200, ranked_usage()}}})
    later = auto_fixture(pool, later_fake, 48)
    earlier = auto_fixture(pool, earlier_fake, 24)
    input = filter_input(pool, api_key, [later, earlier])
    assert {:ok, [{assignment, identity}], options, _state} = route(input)
    assert assignment.id == earlier.assignment.id
    assert identity.id == earlier.identity.id
    assert ResetProbe.bound?(options.routing.reset_probe)
    assert_counts(earlier_fake, 1)
    assert_counts(later_fake, 0)
    applied = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert applied["trigger_kind"] == "gateway_auto"
    assert %{"code" => "reset", "applied" => true} = applied["result"]
    assert Repo.reload!(identity).metadata["saved_resets"]["available_count"] == 1
    assert owned_jobs(earlier.assignment) == []
    {list, cockpit} = open_views(context, identity)
    render_click(list, "open_saved_reset_policy", %{"id" => identity.id})

    for {surface, view} <- [{:bank, list}, {:cockpit, cockpit}] do
      assert has_element?(view, receipt(surface, identity) <> "[data-provider-outcome='applied']")
      assert has_element?(view, heading(surface, identity), "Reset applied")
      refute has_element?(view, receipt(surface, identity) <> " [data-role='saved-reset-request']")
    end

    # The returned generation candidate is deliberately not dispatched.
    record("ranked-receipt", "ranked_blocked_recovery_receipt", %{opposite_input_expiry_order: true, preferred_exact_pair: true, trigger_kind: applied["trigger_kind"], generation: applied["generation"], preferred_counts: FakeUpstream.physical_counts(earlier_fake), other_counts: FakeUpstream.physical_counts(later_fake), manual_requests: 0})
    finish(context, [list, cockpit], [earlier_fake, later_fake], "ranked")
  end

  for veto <- [:ordinary, :credits] do
    test "ranked recovery #{veto} capacity veto adds no consume", context do
      veto = unquote(veto)
      pool = pool_fixture(%{created_by_user_id: context.scope.user.id})
      %{api_key: api_key} = active_api_key_fixture(pool)
      fake = fake!(context, {:path_json, %{@consume => {200, %{"code" => "reset"}}, @usage => {200, ranked_usage()}}})
      blocked = auto_fixture(pool, fake, 24)
      serving = active_upstream_assignment_fixture(pool, %{metadata: metadata(fake, 0)})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      payload = CodexPooler.ProviderCreditsFixtures.usage_payload(unquote(if(veto == :ordinary, do: :included, else: :weekly_credit_only)), now: now)
      CodexPooler.ProviderCreditsFixtures.persist_usage!(serving.identity, payload, now)
      input = filter_input(pool, api_key, [blocked, serving])
      assert {:ok, candidates, _options, _state} = route(input)
      assert Enum.any?(candidates, fn {assignment, _} -> assignment.id == serving.assignment.id end)
      assert_counts(fake, 0)
      refute Repo.reload!(blocked.identity).metadata["saved_reset_redemption"]
      record("ranked-receipt", Atom.to_string(veto), %{veto: veto, physical_counts: FakeUpstream.physical_counts(fake), blocked_lifecycle_absent: true})
      finish(context, [], [fake], "ranked_" <> Atom.to_string(veto))
    end
  end

  for refusal <- [:ambiguous, :nothing_to_reset] do
    test "ranked recovery #{refusal} cannot consume the next eligible account", context do
      refusal = unquote(refusal)
      pool = pool_fixture(%{created_by_user_id: context.scope.user.id})
      %{api_key: api_key} = active_api_key_fixture(pool)
      later_fake = fake!(context, {:path_json, %{@consume => {200, %{"code" => "reset"}}, @usage => {200, ranked_usage()}}})
      response = refused_consume(refusal)
      earlier_fake = fake!(context, {:path_json, %{@consume => response, @usage => {200, ranked_usage()}}})
      later = auto_fixture(pool, later_fake, 48)
      earlier = auto_fixture(pool, earlier_fake, 24)
      input = filter_input(pool, api_key, [later, earlier])
      assert {:error, _} = route(input)
      assert_counts(earlier_fake, 1)
      assert_counts(later_fake, 0)
      outcome = Repo.reload!(earlier.identity).metadata["saved_reset_redemption"]
      assert outcome["trigger_kind"] == "gateway_auto"

      if unquote(refusal == :ambiguous) do
        assert outcome["phase"] == "consuming"
        assert outcome["provider_replay"]["provider_dispatches"] == 1
        assert {:error, _} = route(input)
        assert_counts(earlier_fake, 1)
        assert_counts(later_fake, 0)
      else
        assert %{"code" => "nothing_to_reset", "applied" => false} = outcome["result"]
      end

      {list, cockpit} = open_views(context, earlier.identity)
      render_click(list, "open_saved_reset_policy", %{"id" => earlier.identity.id})
      expected = unquote(if(refusal == :ambiguous, do: "unknown", else: "not_applied"))

      for {surface, view} <- [{:bank, list}, {:cockpit, cockpit}] do
        assert has_element?(view, receipt(surface, earlier.identity) <> "[data-provider-outcome='#{expected}']")
        refute has_element?(view, receipt(surface, earlier.identity) <> " [data-role='saved-reset-request']")
      end

      record("ranked-receipt", Atom.to_string(refusal), %{provider_outcome: expected, trigger_kind: "gateway_auto", preferred_counts: FakeUpstream.physical_counts(earlier_fake), other_counts: FakeUpstream.physical_counts(later_fake)})
      finish(context, [list, cockpit], [earlier_fake, later_fake], "ranked_" <> Atom.to_string(refusal))
    end
  end

  defp refused_consume(:ambiguous), do: FakeUpstream.close_before_headers()
  defp refused_consume(:nothing_to_reset), do: {200, %{"code" => "nothing_to_reset"}}

  defp manual_fixture(context, fake) do
    pool = pool_fixture(%{created_by_user_id: context.scope.user.id})
    fixture = active_upstream_assignment_fixture(pool, %{metadata: metadata(fake, 1)})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, _} = QuotaWindows.record_evidence(fixture.identity, weekly("100", now, DateTime.add(now, 5, :day)), now)
    Map.merge(fixture, %{pool: pool, fake: fake})
  end

  defp metadata(fake, count) do
    now = DateTime.utc_now()
    %{"credential_epoch" => 1, "usage_base_url" => FakeUpstream.url(fake), "usage_path" => @usage, "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(now, 2, :day)), "token_refresh" => %{"status" => "succeeded", "finished_at" => DateTime.to_iso8601(now)}, "saved_resets" => %{"status" => "reported", "available_count" => count, "source" => "codex_usage_api", "path_style" => "codex_api", "observed_at" => DateTime.to_iso8601(now), "usage_path" => @usage}}
  end

  defp auto_fixture(pool, fake, expires_hours) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stored = metadata(fake, 2)
    stored = put_in(stored, ["saved_resets", "expires_detail_status"], "authoritative_rows")
    stored = put_in(stored, ["saved_resets", "expires_observed_at"], DateTime.to_iso8601(now))
    stored = put_in(stored, ["saved_resets", "available_expires_at"], [DateTime.to_iso8601(DateTime.add(now, expires_hours, :hour))])
    fixture = active_upstream_assignment_fixture(pool, %{metadata: stored})
    identity = fixture.identity |> Ecto.Changeset.change(saved_reset_auto_redeem_enabled: true, saved_reset_auto_redeem_trigger_mode: "blocked", saved_reset_auto_redeem_min_blocked_minutes: 60, saved_reset_auto_redeem_keep_credits: 0) |> Repo.update!()
    assert {:ok, _} = QuotaWindows.record_evidence(identity, weekly("100", now, DateTime.add(now, 2, :hour)), now)
    SavedResetConfirmationFixtures.confirm_automatic_pressure!(identity)
    %{fixture | identity: Repo.reload!(identity)}
  end

  defp filter_input(pool, api_key, fixtures) do
    candidates = Enum.map(fixtures, &{&1.assignment, &1.identity})
    model = model_fixture(pool, %{exposed_model_id: "gpt-reset-journey-#{System.unique_integer([:positive])}", metadata: %{"source_assignment_ids" => Enum.map(fixtures, & &1.assignment.id)}})
    payload = %{"model" => model.exposed_model_id, "input" => "sample"}
    options = %{} |> RequestOptions.build("/backend-api/codex/responses", payload) |> RequestOptions.put_routing(reset_probe: ResetProbe.new())
    FilterInput.new(%{auth: %{pool: pool, api_key: api_key}, model: model, endpoint: "/backend-api/codex/responses", payload: payload, request_options: options, candidates: candidates})
  end

  defp route(input) do
    input = FilterInput.put_candidates(input, Enum.map(input.candidates, fn {assignment, identity} -> {assignment, Repo.reload!(identity)} end))
    state = RouteState.new(%{visible_model: input.model, candidates: input.candidates}) |> RouteState.preload_routing_snapshots(input.auth, input.model, input.request_options)
    RouteFiltering.filter_candidates_with_route_state(input, state)
  end

  defp advance_fixture(identity, claim, consumed_at, canonical_at, candidate_at) do
    Repo.delete_all(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id)
    {:ok, actual_consumed_at, 0} = DateTime.from_iso8601(claim["consumed_at"])
    delta = DateTime.diff(consumed_at, actual_consumed_at, :microsecond)
    shifted = shift_fixture_timeline(claim, delta)
    assert shifted["consumed_at"] == DateTime.to_iso8601(consumed_at)
    {:ok, dispatch_at, 0} = DateTime.from_iso8601(shifted["provider_replay"]["last_provider_dispatched_at"])
    assert DateTime.compare(dispatch_at, consumed_at) != :gt
    identity = Repo.reload!(identity)
    stored = identity.metadata |> Map.put("saved_reset_redemption", shifted) |> put_in(["saved_resets", "observed_at"], DateTime.to_iso8601(consumed_at))
    identity |> Ecto.Changeset.change(metadata: stored) |> Repo.update!()
    assert {:ok, _} = QuotaWindows.record_evidence(identity, weekly("100", canonical_at, DateTime.add(canonical_at, 5, :day)), canonical_at)
    assert {:ok, pending} = QuotaWindows.record_evidence(identity, weekly("0", candidate_at, DateTime.add(candidate_at, @week, :second), @week), candidate_at)
    assert Decimal.equal?(pending.used_percent, Decimal.new("100"))
    assert {:ok, %{observed_at: ^candidate_at}} = EvidenceStore.parse_candidate(pending.metadata)
  end

  defp shift_fixture_timeline(value, delta) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, shift_fixture_timeline(child, delta)} end)
  end

  defp shift_fixture_timeline(value, delta) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, 0} -> timestamp |> DateTime.add(delta, :microsecond) |> DateTime.to_iso8601()
      _not_a_timestamp -> value
    end
  end

  defp shift_fixture_timeline(value, _delta), do: value

  defp fetch_usage(context, fixture, observed_at, payload) do
    release = make_ref()
    FakeUpstream.set_mode(fixture.fake, {:path_json, %{@usage => FakeUpstream.gated_json_headers(payload, notify: self(), release_ref: release)}})
    task = task!(context, fn -> PoolReconciliation.refresh_quota_from_usage(Repo.reload!(fixture.identity), fixture.assignment, observed_at: observed_at) end)
    monitor = CodexPooler.TestProcess.monitor_flushed(task.pid)
    assert_receive {:fake_upstream_gate, :before_headers, request_pid, ^release}, @detection_timeout
    remember(context, {:gate, request_pid, :fake_upstream_release_gate, release})
    send(request_pid, {:fake_upstream_release_gate, release})
    assert {:ok, _} = Task.await(task, @detection_timeout)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, @detection_timeout
  end

  defp weekly(percent, observed_at, reset_at, seconds \\ nil) do
    %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, used_percent: Decimal.new(percent), reset_at: reset_at, observed_at: observed_at, last_sync_at: observed_at, source: "codex_usage_api", source_precision: "observed", freshness_state: "fresh", metadata: if(seconds, do: %{"reset_after_seconds" => seconds, "rate_limit_allowed" => true, "rate_limit_reached" => false}, else: %{})}
  end

  defp ranked_usage do
    payload = usage(1, DateTime.utc_now(), 10, 900)
    payload |> put_in(["rate_limit"], %{"allowed" => true, "limit_reached" => false, "primary_window" => payload["rate_limit"]["secondary_window"]}) |> Map.put("credits", %{"has_credits" => false, "unlimited" => false, "balance" => "0"}) |> Map.put("spend_control", %{"reached" => false})
  end

  defp usage(count, observed_at, percent \\ 0, reset_seconds \\ @week) do
    %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => count}, "rate_limit" => %{"allowed" => true, "limit_reached" => false, "secondary_window" => %{"used_percent" => percent, "limit_window_seconds" => @week, "reset_after_seconds" => reset_seconds, "reset_at" => DateTime.to_unix(DateTime.add(observed_at, reset_seconds, :second))}}}
  end

  defp open_views(context, identity) do
    {:ok, list, _} = live(context.conn, ~p"/admin/upstreams")
    remember(context, {:view, list})
    {:ok, cockpit, _} = live(context.conn, ~p"/admin/upstreams/#{identity.id}")
    remember(context, {:view, cockpit})
    {list, cockpit}
  end

  defp submit_one(list, fixture) do
    assert owned_jobs(fixture.assignment) == []
    render_click(list, "redeem_saved_reset", target(fixture))
    assert owned_jobs(fixture.assignment) == []
    render_click(list, "open_saved_reset_redemption_confirmation", target(fixture))
    assert has_element?(list, "#saved-reset-redemption-confirmation", "The provider may apply it before quota checks finish")
    list |> element("#saved-reset-redemption-confirm") |> render_click()
    assert [job] = owned_jobs(fixture.assignment)
    assert [runnable] = Repo.all(from job in Oban.Job, where: job.queue == "jobs" and job.state == "available")
    assert runnable.id == job.id
    job
  end

  defp target(fixture), do: %{"id" => fixture.identity.id, "pool-id" => fixture.pool.id}
  defp owned_jobs(assignment), do: Repo.all(from job in Oban.Job, where: job.worker == ^@worker and fragment("?->>'pool_upstream_assignment_id'", job.args) == ^assignment.id)
  defp drain_queue, do: Oban.drain_queue(queue: :jobs, with_limit: 1, with_recursion: false, with_scheduled: false, with_safety: false)
  defp drain_task(context), do: task!(context, &drain_queue/0)

  defp task!(context, fun) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(context.task_supervisor, fn ->
        Sandbox.allow(Repo, parent, self())
        fun.()
      end)

    remember(context, {:task, task.pid})
    task
  end

  defp refresh_views(views, identity) do
    Enum.each(views, fn view ->
      render_click(view, "refresh_saved_reset_status", %{"id" => identity.id})
      settle(view)
    end)
  end

  defp settle(view, attempts \\ 10)
  defp settle(_view, 0), do: flunk("owned status reads did not finish")

  defp settle(view, attempts) do
    render_async(view, @detection_timeout)
    assigns = :sys.get_state(view.pid).socket.assigns
    if assigns[:saved_reset_status_running] || assigns[:saved_reset_status_rerun] || assigns[:upstreams_reload_running?], do: settle(view, attempts - 1), else: :ok
  end

  defp receipt(surface, identity), do: "#saved-reset-operation-#{surface}-#{identity.id}"
  # The disclosure summary: the receipt's only heading, carrying its headline.
  defp heading(surface, identity), do: "#saved-reset-operation-heading-#{surface}-#{identity.id}"

  defp assert_operation(views, identity, outcome, verification) do
    for {surface, view} <- views do
      assert has_element?(view, receipt(surface, identity) <> "[data-provider-outcome='#{outcome}'][data-verification-state='#{verification}']"), "current operation outcome or verification differs from the expected bounded selector"
    end
  end

  defp fake!(context, mode) do
    name = String.to_atom("reset_workflow_fake_#{System.unique_integer([:positive])}")
    remember(context, {:fake_name, name})
    {:ok, fake} = FakeUpstream.start_link(mode, supervisor_name: name)
    Process.unlink(fake.supervisor)
    remember(context, {:fake, fake})
    fake
  end

  defp remember(context, resource), do: Agent.update(context.resources, &[resource | &1])

  defp assert_counts(fake, consumes) do
    counts = FakeUpstream.physical_counts(fake)
    assert counts.consume == consumes
    assert counts.http_generation == 0
    assert counts.websocket_generation == 0
  end

  defp stop_view(view) do
    monitor = CodexPooler.TestProcess.monitor_flushed(view.pid)
    {_ref, _topic, proxy} = view.proxy

    try do
      ClientProxy.stop(proxy, {:shutdown, :cleanup})
    catch
      :exit, _ -> :ok
    end

    assert_receive {:DOWN, ^monitor, :process, _, _}, @detection_timeout
  end

  defp stop_pid(pid) do
    Process.unlink(pid)
    monitor = CodexPooler.TestProcess.monitor_flushed(pid)

    try do
      GenServer.stop(pid, :normal, @detection_timeout)
    catch
      :exit, _ -> :ok
    end

    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, @detection_timeout
  end

  defp finish(context, views, fakes, scenario) do
    Enum.each(views, &stop_view/1)

    Enum.each(fakes, fn fake ->
      :ok = FakeUpstream.stop(fake)
      refute Process.alive?(fake.pid)
      refute Process.alive?(fake.server)
      refute Process.alive?(fake.supervisor)
    end)

    stop_pid(context.task_supervisor)

    alive =
      Agent.get(
        context.resources,
        &Enum.count(&1, fn
          {:view, view} -> Process.alive?(view.pid)
          {:task, pid} -> Process.alive?(pid)
          {:fake, fake} -> Process.alive?(fake.supervisor)
          {:fake_name, name} -> not is_nil(Process.whereis(name))
          {:task_supervisor, pid} -> Process.alive?(pid)
          {:gate, _pid, _kind, _ref} -> false
        end)
      )

    assert alive == 0
    Agent.stop(context.resources)
    refute Process.alive?(context.resources)
    record("cleanup", scenario, %{owned_liveviews_tasks_fake_supervisors_alive: alive, task_supervisor_alive: false, resource_tracker_alive: false})
  end

  defp stop_named(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> stop_pid(pid)
    end
  end

  defp await_task_exit(pid) do
    monitor = CodexPooler.TestProcess.monitor_flushed(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, @detection_timeout
  end

  defp cleanup_registered(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      tracker ->
        resources = Agent.get(tracker, & &1)
        for {:gate, pid, kind, ref} <- resources, do: send(pid, {kind, ref})
        for {:view, view} <- resources, do: stop_view(view)
        # Closing owned HTTP connections also releases a handler whose gate
        # notice never reached the test. Let writers finish before owner teardown.
        for {:fake, fake} <- resources, do: FakeUpstream.stop(fake)
        for {:fake_name, name} <- resources, do: stop_named(name)
        for {:task, pid} <- resources, do: await_task_exit(pid)
        for {:task_supervisor, pid} <- resources, do: stop_pid(pid)

        Agent.stop(tracker)
    end
  end

  defp record(kind, scenario, facts) do
    case System.get_env("SAVED_RESET_WORKFLOW_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        File.mkdir_p!(directory)
        File.write!(Path.join(directory, "task-11-#{kind}-#{scenario}.json"), Jason.encode!(Map.put(facts, :scenario, scenario), pretty: true))
    end
  end
end
