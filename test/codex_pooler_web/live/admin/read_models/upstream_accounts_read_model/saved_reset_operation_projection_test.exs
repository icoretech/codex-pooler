defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetOperationProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Admin.{UpstreamQuotaReadiness, UpstreamRoutingReadiness}
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetOperationProjection, as: Projection
  alias CodexPoolerWeb.DateTimeDisplay

  @now ~U[2026-07-14 03:30:00.000000Z]
  @started ~U[2026-07-14 03:29:40.000000Z]
  @consumed ~U[2026-07-14 03:29:45.000000Z]
  @prefs DateTimeDisplay.preferences_for_user(nil)
  @unknown_caveat "The request may have reached the provider. Don't redeem again until this resolves."
  @refused_caveat "The provider reported that the reset was not applied."

  defp context(extra \\ %{}) do
    readiness = UpstreamRoutingReadiness.from_inputs("active", [], UpstreamQuotaReadiness.from_windows([], @now))
    Map.merge(%{snapshot_at: @now, datetime_preferences: @prefs, serving_readiness: readiness}, extra)
  end

  defp redemption(phase, code \\ "reset", applied \\ true) do
    %{
      "phase" => phase,
      "status" => if(phase in ["consuming", "consumed_pending_probe"], do: "redeeming", else: "succeeded"),
      "started_at" => DateTime.to_iso8601(@started),
      "consumed_at" => DateTime.to_iso8601(@consumed),
      "finished_at" => DateTime.to_iso8601(@consumed),
      "deadline_at" => DateTime.to_iso8601(DateTime.add(@consumed, 15, :minute)),
      "result" => %{"code" => code, "applied" => applied, "http_status" => 200, "available_count_before" => 2, "available_count_after" => 1}
    }
  end

  defp project(record, extra \\ %{}), do: Projection.project(context(Map.put(extra, :redemption, record)))

  defp manual_replacement(phase, count) do
    consumed = DateTime.add(@now, -2, :day)

    receipt = %{
      "phase" => "expired",
      "status" => "failed",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 3,
      "included_window_descriptors" => [],
      "started_at" => DateTime.to_iso8601(DateTime.add(consumed, -1, :second)),
      "consumed_at" => DateTime.to_iso8601(consumed),
      "deadline_at" => DateTime.to_iso8601(DateTime.add(consumed, 15, :minute)),
      "finished_at" => DateTime.to_iso8601(DateTime.add(consumed, 16, :minute)),
      "result" => %{"applied" => true, "code" => "reset"},
      "provider_replay" => %{"version" => 1, "provider_dispatches" => 1, "endpoint_family" => "chatgpt_api", "scope_fingerprint" => String.duplicate("a", 64)}
    }

    %{
      "phase" => phase,
      "status" => if(phase == "consuming", do: "redeeming", else: "failed"),
      "trigger_kind" => "admin_manual",
      "started_at" => DateTime.to_iso8601(@started),
      "manual_replacement" => %{"version" => 1, "credential_epoch" => 15, "window_id" => Ecto.UUID.generate(), "reset_at" => DateTime.to_iso8601(DateTime.add(@now, 6, :day)), "receipt" => receipt},
      "provider_replay" => %{"version" => 2, "provider_dispatches" => count}
    }
  end

  test "version two manual replacement remains in progress while its provider answer is pending" do
    result = project(manual_replacement("consuming", 1))
    assert result.active?
    assert result.headline == "Reset request in progress"
    assert result.provider_outcome == :unknown
    refute Map.has_key?(result, :consumed_at)
  end

  test "version two zero-dispatch terminal receipt truthfully reports no application" do
    record = manual_replacement("manual_replacement_not_applied", 0) |> Map.put("result", %{"code" => "consume_not_applied", "applied" => false})
    result = project(record)
    assert result.provider_outcome == :not_applied
    assert result.verification == :not_started
    assert result.headline == "Reset was not applied"
    refute result.active?
    refute result.unresolved?
    refute Map.has_key?(result, :consumed_at)
    assert Projection.observe(result, paused?: true).headline == result.headline
    assert Projection.observe(result, connected?: false).headline == result.headline
  end

  test "version two definitive provider noops retain their specific outcome" do
    for {code, headline} <- [{"no_credit", "No saved reset was available"}, {"nothing_to_reset", "Nothing needed resetting"}] do
      record = manual_replacement("manual_replacement_not_applied", 1) |> Map.put("result", %{"code" => code, "applied" => false})
      result = project(record)
      assert result.provider_outcome == :not_applied
      assert result.headline == headline
      refute result.active?
      refute Map.has_key?(result, :consumed_at)
    end
  end

  test "version two applied result keeps verification and does not expose its historical context" do
    record = Map.merge(manual_replacement("consumed_pending_probe", 1), redemption("consumed_pending_probe"))
    result = project(record)
    assert result.provider_outcome == :applied
    assert result.verification == :pending
    refute Map.has_key?(result, :manual_replacement)
    refute inspect(result) =~ record["manual_replacement"]["receipt"]["attempt_id"]
  end

  test "version two replay without a valid bounded context stays unknown" do
    record = manual_replacement("manual_replacement_not_applied", 0) |> Map.put("result", %{"code" => "consume_not_applied", "applied" => false})

    for invalid <- [nil, %{}, Map.put(record["manual_replacement"], "extra", true), put_in(record["manual_replacement"], ["receipt", "result", "applied"], false)] do
      result = project(Map.put(record, "manual_replacement", invalid))
      assert result.provider_outcome == :unknown
      refute result.headline == "Reset was not applied"
    end

    assert project(Map.delete(manual_replacement("consuming", 1), "manual_replacement")).headline == "Reset outcome not confirmed"
  end

  @tag :operation_truth_matrix
  test "current applied and recovered results independently preserve quota verification and readiness" do
    for code <- ["reset", "already_redeemed", "target_redeemed"] do
      result = project(redemption("consumed_pending_probe", code))
      assert result.provider_outcome == :applied
      assert result.verification == :pending
      assert result.headline == "Reset applied — verifying quota"
      assert result.summary == "Waiting for a usage report to confirm the new quota."
      assert result.serving_readiness == context().serving_readiness
      assert result.active? and result.refreshable? and result.show_latest_receipt?
      assert result.consumed_at == DateTimeDisplay.format_datetime(@consumed, @prefs)
      assert is_binary(result.started_at) and is_binary(result.finished_at) and is_binary(result.deadline_at)
    end
  end

  @tag :operation_truth_matrix
  test "candidate, quota confirmation and request verification remain distinct" do
    candidate = %{confirmation_state: :awaiting_confirmation, challenged_evidence_state: :candidate_progressing}
    assert project(redemption("consumed_pending_probe"), %{confirmation: candidate}).verification == :candidate

    quota = project(redemption("confirmed_by_quota"))
    assert quota.verification == :quota_confirmed
    assert quota.headline == "Quota confirmed"
    refute quota.active?
    assert quota.show_latest_receipt?

    request = project(redemption("confirmed_by_upstream"))
    assert request.verification == :request_verified
    assert request.headline == "Recovery verified by a request"
    assert request.summary == "A request succeeded on the new quota; the usage report has not caught up yet."
  end

  @tag :operation_truth_matrix
  test "definitive noops require explicit matching application facts" do
    for {code, headline, summary} <- [{"no_credit", "No saved reset was available", "The provider had no saved reset to apply."}, {"nothing_to_reset", "Nothing needed resetting", "The provider found no exhausted quota to reset."}] do
      result = project(%{"status" => "noop", "result" => %{"code" => code, "applied" => false}})
      assert result.provider_outcome == :not_applied
      assert result.verification == :not_started
      assert result.headline == headline
      assert result.summary == summary
      # The provider answered, so its refusal is the provider's; the summary already says so, hence no repeated detail line.
      assert result.outcome_caveat == @refused_caveat
      assert result.detail == nil
      refute Map.has_key?(result, :consumed_at)
      assert result.show_latest_receipt?
    end
  end

  @tag :operation_truth_matrix
  test "consume_not_applied needs the version one zero-dispatch replay contract" do
    record = %{"phase" => "consume_not_applied", "result" => %{"code" => "consume_not_applied", "applied" => false}, "provider_replay" => %{"version" => 1, "provider_dispatches" => 0}}
    result = project(record)
    assert result.provider_outcome == :not_applied
    assert result.headline == "Reset was not applied"
    assert result.summary == "The request stopped before reaching the provider."
    # Zero dispatches means the provider never saw the request, so it is never described as the provider's refusal.
    assert result.outcome_caveat == "The request stopped before reaching the provider."
    refute result.outcome_caveat == @refused_caveat
    assert result.detail == nil
  end

  @tag :operation_truth_matrix
  test "zero-dispatch observe-only settlement retains a known non-dispatch recovery observation" do
    # enter_observe_only!/4 and persist_observe_only_locked!/4 retain these codes;
    # settle_consume_not_applied!/5 preserves the replay map on the terminal record.
    for code <- ["write_budget_exhausted", "scope_changed"] do
      record = %{
        "phase" => "consume_not_applied",
        "status" => "failed",
        "started_at" => DateTime.to_iso8601(DateTime.add(@now, -30, :minute)),
        "finished_at" => DateTime.to_iso8601(@now),
        "result" => %{"code" => "consume_not_applied", "applied" => false, "available_count_before" => nil, "available_count_after" => nil, "http_status" => nil},
        "provider_replay" => %{
          "version" => 1,
          "endpoint_family" => "codex_api",
          "scope_fingerprint" => "synthetic-scope-fingerprint",
          "provider_dispatches" => 0,
          "mode" => "observe_only",
          "replay_exhausted_at" => DateTime.to_iso8601(@now),
          "unresolved_since" => DateTime.to_iso8601(@now),
          "next_action_at" => DateTime.to_iso8601(@now),
          "last_code" => code
        }
      }

      result = project(record)
      assert result.provider_outcome == :not_applied
      assert result.headline == "Reset was not applied"
      assert result.verification == :not_started
      refute Map.has_key?(result, :consumed_at)
      assert project(put_in(record, ["provider_replay", "last_provider_dispatched_at"], DateTime.to_iso8601(@started))).provider_outcome == :unknown
      assert project(put_in(record, ["provider_replay", "last_code"], "transport_error")).provider_outcome == :unknown
      assert project(put_in(record, ["provider_replay", "provider_dispatches"], 1)).provider_outcome == :unknown
      assert project(put_in(record, ["provider_replay", "mode"], "replay")).provider_outcome == :unknown
    end
  end

  @tag :operation_truth_matrix
  test "a new accepted request and an older latest receipt stay separate" do
    summary = %{open: %{state: :queued, requested_at: @now, scheduled_at: DateTime.add(@now, 5, :second)}, latest_terminal: nil}
    result = project(redemption("confirmed_by_quota"), %{request_summary: summary})
    assert result.request.state == :queued
    assert result.request.headline == "Request accepted"
    assert result.request.summary == "Queued. Nothing has been sent to the provider yet."
    assert is_binary(result.request.requested_at) and is_binary(result.request.scheduled_at)
    assert result.provider_outcome == :applied and result.verification == :quota_confirmed
    assert result.headline == "Quota confirmed"
    assert result.active? and result.show_latest_receipt?
  end

  @tag :operation_truth_matrix
  test "normal fresh consuming distinguishes in progress from application" do
    # build_redemption_claim!/9 persists the result key before a provider reply exists.
    result = project(%{"phase" => "consuming", "status" => "redeeming", "result" => nil, "started_at" => DateTime.to_iso8601(@started)})
    assert result.provider_outcome == :unknown
    assert result.verification == :not_started
    assert result.headline == "Reset request in progress"
    assert result.summary == "Waiting for the provider's answer."
    refute Map.has_key?(result, :consumed_at)
    refute Map.has_key?(result, :deadline_at)
  end

  @tag :operation_truth_matrix
  test "reblocked and expired preserve independently proven application" do
    for {phase, verification, headline, summary} <- [
          {"reblocked", :reblocked, "Quota is still unavailable", "The reset was applied, but quota is still blocked. No further reset is spent automatically."},
          {"expired", :expired, "Quota confirmation timed out", "No usage report confirmed the new quota in time. The spent reset is not refunded."}
        ] do
      result = project(redemption(phase))
      assert result.provider_outcome == :applied
      assert result.verification == verification
      assert result.headline == headline
      assert result.summary == summary
      assert result.detail == nil
      assert result.show_latest_receipt?
    end

    # Application is stated only where the provider outcome proves it: any other outcome gets neutral wording and its own caveat.
    for {phase, verification, summary} <- [{"reblocked", :reblocked, "Quota is still blocked."}, {"expired", :expired, "No usage report confirmed the new quota in time."}],
        {record, outcome, caveat} <- [{redemption(phase, "no_credit", false) |> Map.delete("consumed_at"), :not_applied, @refused_caveat}, {%{"phase" => phase}, :unknown, @unknown_caveat}] do
      result = project(record)
      assert result.provider_outcome == outcome and result.verification == verification
      assert result.summary == summary
      assert result.detail == caveat
      refute result.summary =~ ~r/was applied|spent reset/
    end
  end

  @tag :operation_truth_matrix
  test "polling and view pauses are observations without changing outcome or readiness" do
    pause = %{paused_until: DateTime.add(@now, 5, :minute), paused_until_label: "ignored", remaining_label: "ignored", status_code: 429, origin_label: "ignored", origin_count: 1}
    result = project(redemption("consumed_pending_probe"), %{usage_poll_pause: pause, view_paused?: true, last_checked_at: @now})
    assert result.headline == "Quota checks are delayed"
    assert result.provider_outcome == :applied and result.verification == :pending
    assert result.view_paused?
    assert result.usage_poll_pause.state == :paused
    assert is_binary(result.pause_until) and is_binary(result.last_checked_at)
    assert result.refreshable?
    disconnected = project(redemption("consumed_pending_probe"), %{view_connected?: false})
    assert disconnected.headline == "Live updates disconnected"
    assert disconnected.provider_outcome == :applied
    assert project(redemption("consumed_pending_probe"), %{view_paused?: true}).headline == "Live updates paused"
    assert project(redemption("consumed_pending_probe"), %{usage_poll_pause: :unavailable}).headline == "Quota checks are delayed"
  end

  @tag :operation_truth_matrix
  test "an unresolved outcome keeps its redemption warning under every observation override" do
    unresolved = %{"phase" => "consuming", "started_at" => DateTime.to_iso8601(DateTime.add(@now, -1, :hour))}
    pause = %{paused_until: DateTime.add(@now, 5, :minute)}

    # Each override replaces the summary, so the warning has to survive as the detail line.
    for {name, extra} <- [paused: %{view_paused?: true}, disconnected: %{view_connected?: false}, polling_unavailable: %{usage_poll_pause: :unavailable}, polling_paused: %{usage_poll_pause: pause}] do
      result = project(unresolved, extra)
      assert result.provider_outcome == :unknown, "#{name}"
      refute result.headline == "Reset outcome not confirmed", "#{name}"
      refute result.summary =~ "Don't redeem again", "#{name}"
      assert result.detail == @unknown_caveat, "#{name}"
    end

    # The LiveViews apply the same overrides to an operation that is already projected.
    operation = project(unresolved)
    assert operation.summary == @unknown_caveat
    assert operation.detail == nil
    assert Projection.observe(operation, paused?: true) == project(unresolved, %{view_paused?: true})
    assert Projection.observe(operation, connected?: false) == project(unresolved, %{view_connected?: false})
    assert Projection.observe(operation, []) == operation

    # A resolved outcome has no warning to preserve.
    assert project(redemption("consumed_pending_probe"), %{view_paused?: true}).detail == nil
  end

  @tag :unknown_and_contradictory_outcomes
  test "missing malformed contradictory and legacy results cannot establish application" do
    for record <- [nil, %{}, %{"phase" => "confirmed_by_quota"}, %{"phase" => "expired"}, %{"phase" => "reblocked"}, %{"result" => []}, %{"result" => %{"code" => "reset"}}, %{"result" => %{"code" => "reset", "applied" => false}}, %{"result" => %{"code" => "no_credit", "applied" => true}}, %{"result" => %{"code" => "transport_error", "applied" => false}}, %{"result" => %{"code" => "target_redeemed", "applied" => "true"}}] do
      result = project(record)
      assert result.provider_outcome in [:unknown, :not_recorded]
      refute Map.has_key?(result, :consumed_at)
    end

    legacy = project(%{"phase" => "confirmed_by_quota"})
    assert legacy.verification == :quota_confirmed
    assert legacy.provider_outcome == :unknown
    assert legacy.summary == "The new quota cycle is confirmed."
    assert legacy.detail == @unknown_caveat
  end

  @tag :unknown_and_contradictory_outcomes
  test "zero-dispatch claims fail closed for malformed contradictory replay evidence" do
    for replay <- [nil, [], %{}, %{"version" => 2, "provider_dispatches" => 0}, %{"version" => 1, "provider_dispatches" => 1}, %{"version" => 1, "provider_dispatches" => "0"}, %{"version" => 1, "provider_dispatches" => 0, "last_provider_dispatched_at" => DateTime.to_iso8601(@started)}, %{"version" => 1, "provider_dispatches" => 0, "last_code" => "transport_error"}] do
      result = project(%{"phase" => "consume_not_applied", "result" => %{"code" => "consume_not_applied", "applied" => false}, "provider_replay" => replay})
      assert result.provider_outcome == :unknown
      assert result.headline == "Reset outcome not confirmed"
    end

    contradiction = redemption("consumed_pending_probe") |> Map.put("provider_replay", %{"version" => 1, "provider_dispatches" => 0})
    assert project(contradiction).provider_outcome == :unknown
  end

  @tag :unknown_and_contradictory_outcomes
  test "authoritative-looking application cannot override malformed persisted replay shapes" do
    for replay <- [[], %{}, %{"version" => 1, "provider_dispatches" => -1}, %{"version" => 2, "provider_dispatches" => 1}, %{"version" => 1, "provider_dispatches" => "1"}] do
      result = project(Map.put(redemption("consumed_pending_probe"), "provider_replay", replay))
      assert result.provider_outcome == :unknown
      assert result.headline == "Reset outcome not confirmed"
    end

    recovered = redemption("consumed_pending_probe", "target_redeemed") |> Map.put("provider_replay", %{"version" => 1, "provider_dispatches" => 1, "last_code" => "transport_error", "last_provider_dispatched_at" => DateTime.to_iso8601(@started)})
    assert project(recovered).provider_outcome == :applied
  end

  @tag :unknown_and_contradictory_outcomes
  test "ambiguity stale execution and future clocks never become no-spend proof" do
    consuming = %{"phase" => "consuming", "started_at" => DateTime.to_iso8601(@started)}

    for replay <- [%{"version" => 1, "provider_dispatches" => 1, "last_code" => "transport_error"}, %{"version" => 1, "provider_dispatches" => 1, "last_code" => "no_credit"}, %{"last_code" => "synthetic-provider-detail"}, []] do
      result = project(Map.put(consuming, "provider_replay", replay))
      assert result.provider_outcome == :unknown
      assert result.headline == "Reset outcome not confirmed"
      assert result.summary =~ "Don't redeem again until this resolves."
    end

    for started <- [DateTime.add(@now, -76, :second), DateTime.add(@now, 1, :second)] do
      assert project(Map.put(consuming, "started_at", DateTime.to_iso8601(started))).headline == "Reset outcome not confirmed"
    end

    future = redemption("consumed_pending_probe") |> Map.put("consumed_at", DateTime.to_iso8601(DateTime.add(@now, 1, :second)))
    result = project(future)
    assert result.provider_outcome == :unknown
    refute Map.has_key?(result, :consumed_at)
  end

  @tag :unknown_and_contradictory_outcomes
  test "elapsed clock reports a deadline without fabricating persisted expiry" do
    result = project(redemption("consumed_pending_probe") |> Map.put("deadline_at", DateTime.to_iso8601(DateTime.add(@now, -1, :second))))
    assert result.verification == :pending
    assert result.provider_outcome == :applied
    assert result.headline == "Deadline passed — checking quota"
  end

  @tag :unknown_and_contradictory_outcomes
  test "terminal pruned or unavailable job context never erases a latest receipt or proves application" do
    terminal = %{open: nil, latest_terminal: %{state: :stopped, requested_at: @now, scheduled_at: nil}}

    for summary <- [nil, terminal, :unavailable] do
      result = project(redemption("confirmed_by_quota"), %{request_summary: summary})
      assert result.provider_outcome == :applied and result.show_latest_receipt?
    end

    result = project(nil, %{request_summary: terminal})
    assert result.request.state == :stopped
    assert result.provider_outcome == :not_recorded
    refute result.show_latest_receipt?
    result = project(nil, %{request_summary: %{open: %{state: :processing}, latest_terminal: nil}})
    assert result.request.state == :processing and result.provider_outcome == :not_recorded
  end

  @tag :unknown_and_contradictory_outcomes
  test "synthetic private metadata and unrecognized codes never enter output" do
    sentinel = "synthetic-operation-private-detail"
    record = redemption("consuming") |> Map.put("result", %{"code" => sentinel, "applied" => false, "body" => sentinel}) |> Map.put("attempt_id", sentinel) |> Map.put("provider_replay", %{"last_code" => sentinel, "locator" => sentinel}) |> Map.put("terminal_reason", sentinel)
    result = project(record, %{request_summary: %{open: %{state: :queued, args: sentinel, errors: sentinel, job_id: sentinel}, latest_terminal: nil}})
    refute inspect(result) =~ sentinel
    refute Map.has_key?(result, :redemption)
    assert result.provider_outcome == :unknown
  end

  @tag :operation_truth_matrix
  test "a finished request says how its job ended without claiming the latest result" do
    terminal = fn state -> %{open: nil, latest_terminal: %{state: state, requested_at: @started, scheduled_at: @started}} end

    # A completed job adds nothing beside the latest receipt, which is the account's newest recorded result.
    completed = project(redemption("consumed_pending_probe"), %{request_summary: terminal.(:completed)})
    assert completed.request.state == :completed
    refute completed.show_request?
    assert completed.headline == "Reset applied — verifying quota"

    for {state, headline} <- [completed: "Request completed", discarded: "Request did not complete", cancelled: "Request cancelled", stopped: "Request stopped"] do
      alone = project(nil, %{request_summary: terminal.(state)})
      assert alone.show_request?, "#{state}"
      assert {alone.request.headline, alone.request.summary} == {headline, "No reset result is recorded."}
      assert {alone.headline, alone.compact_headline} == {headline, headline}
      refute alone.active?
    end

    noop = %{"status" => "noop", "result" => %{"code" => "no_credit", "applied" => false}}

    for state <- [:discarded, :cancelled, :stopped] do
      beside = project(noop, %{request_summary: terminal.(state)})
      assert beside.show_request?, "#{state}"
      assert beside.request.summary == "Check the latest reset before acting."
      assert beside.headline == "No saved reset was available"
    end
  end

  @tag :operation_truth_matrix
  test "a processing request makes no claim about the provider's answer" do
    processing = %{open: %{state: :processing, requested_at: @started, scheduled_at: @started}, latest_terminal: nil}
    result = project(redemption("consumed_pending_probe"), %{request_summary: processing})
    assert result.request.summary == "Being processed."
    assert result.compact_headline == "Request accepted — processing"
  end

  @tag :operation_truth_matrix
  test "the scheduled time is shown only when it differs from the request time" do
    same = project(nil, %{request_summary: %{open: %{state: :queued, requested_at: @started, scheduled_at: @started}, latest_terminal: nil}})
    assert is_binary(same.request.requested_at)
    refute Map.has_key?(same.request, :scheduled_at)

    later = project(nil, %{request_summary: %{open: %{state: :queued, requested_at: @started, scheduled_at: DateTime.add(@started, 5, :minute)}, latest_terminal: nil}})
    assert is_binary(later.request.requested_at) and is_binary(later.request.scheduled_at)
    refute later.request.requested_at == later.request.scheduled_at
  end

  @tag :operation_truth_matrix
  test "a finished receipt keeps its own copy under every observation" do
    pause = %{paused_until: DateTime.add(@now, 5, :minute)}

    for record <- [redemption("confirmed_by_quota"), redemption("reblocked"), redemption("expired"), %{"status" => "noop", "result" => %{"code" => "no_credit", "applied" => false}}] do
      settled = project(record)
      refute settled.active?

      for extra <- [%{view_paused?: true}, %{view_connected?: false}, %{usage_poll_pause: pause}, %{usage_poll_pause: :unavailable}] do
        observed = project(record, extra)
        assert {observed.headline, observed.summary, observed.detail} == {settled.headline, settled.summary, settled.detail}, "#{record["phase"]} #{inspect(Map.keys(extra))}"
        refute observed.summary =~ "The reset continues"
      end

      assert Projection.observe(settled, paused?: true).headline == settled.headline
      assert Projection.observe(settled, connected?: false).summary == settled.summary
    end

    # The polling pause stays a recorded fact on the finished receipt.
    assert is_binary(project(redemption("confirmed_by_quota"), %{usage_poll_pause: pause}).pause_until)
  end

  @tag :operation_truth_matrix
  test "the compact status line follows the recorded status, not the observation" do
    passed = redemption("consumed_pending_probe") |> Map.put("deadline_at", DateTime.to_iso8601(DateTime.add(@now, -1, :second)))
    assert project(passed, %{view_paused?: true}).compact_headline == "Deadline passed — checking quota"
    assert project(passed, %{view_paused?: true}).headline == "Live updates paused"

    unknown_reblock = project(%{"phase" => "reblocked"})
    assert {unknown_reblock.compact_headline, unknown_reblock.headline} == {"Reset outcome not confirmed", "Quota is still unavailable"}
    assert project(%{"phase" => "consuming", "started_at" => DateTime.to_iso8601(@started)}).compact_headline == "Reset request in progress"
    assert project(%{"phase" => "confirmed_by_quota"}).compact_headline == "Quota confirmed"
    assert project(%{"status" => "noop", "result" => %{"code" => "no_credit", "applied" => false}}, %{view_paused?: true}).compact_headline == "No saved reset was available"
    queued = %{open: %{state: :queued, requested_at: @now}, latest_terminal: nil}
    assert project(redemption("confirmed_by_quota"), %{request_summary: queued, view_connected?: false}).compact_headline == "Request accepted — queued"
  end

  @tag :unknown_and_contradictory_outcomes
  test "a settled record without a lifecycle phase is history, not an unresolved warning" do
    # The claim ignores such a record (no phase), so its unknown outcome never resolves and never holds a redemption back.
    for record <- [%{"status" => "failed", "result" => %{"code" => "transport_error", "applied" => false}}, %{"status" => "failed", "result" => %{"code" => "stale_redemption_unknown", "applied" => false}}, %{"status" => "completed"}] do
      result = project(record)
      assert result.provider_outcome == :unknown
      assert {result.headline, result.summary} == {"Reset outcome not recorded", "It does not block another redemption."}
      assert result.outcome_caveat == nil and result.detail == nil
      assert result.compact_headline == "Reset outcome not recorded"
      refute result.unresolved?
      refute result.active?
      assert Projection.observe(result, paused?: true).headline == "Reset outcome not recorded"
    end

    # A phase-less record still marked redeeming may still be in flight, so it keeps the warning.
    redeeming = project(%{"status" => "redeeming", "started_at" => DateTime.to_iso8601(@started)})
    assert redeeming.active? and redeeming.unresolved?
    assert redeeming.headline == "Reset outcome not confirmed"
    assert project(%{"phase" => "consuming", "started_at" => DateTime.to_iso8601(DateTime.add(@now, -1, :hour))}).unresolved?
    refute project(redemption("confirmed_by_quota")).unresolved?
  end
end
