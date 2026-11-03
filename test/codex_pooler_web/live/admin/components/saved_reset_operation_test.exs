defmodule CodexPoolerWeb.Admin.SavedResetOperationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Admin.Components
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetOperationProjection, as: Projection
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetOperation
  alias CodexPoolerWeb.DateTimeDisplay

  @identity "00000000-0000-4000-8000-000000000001"
  @now ~U[2026-10-05 12:00:00Z]

  @tag :receipt_state_rendering
  test "renders actual applied, candidate, confirmed and provisional receipt states" do
    for {phase, confirmation, expected, headline} <- [
          {"consumed_pending_probe", nil, :pending, "Reset applied — verifying quota"},
          {"consumed_pending_probe", %{challenged_evidence_state: :candidate_progressing}, :candidate, "Reset applied — verifying quota"},
          {"confirmed_by_quota", nil, :quota_confirmed, "Quota confirmed"},
          {"confirmed_by_upstream", nil, :request_verified, "Recovery verified by a request"}
        ] do
      operation = project(%{redemption: applied(phase), confirmation: confirmation})
      html = receipt(operation)
      record_html("#{expected}", html)
      document = LazyHTML.from_fragment(html)
      refute Enum.empty?(LazyHTML.query(document, "section[data-provider-outcome='applied'][data-verification-state='#{expected}']"))
      # The disclosure summary is the receipt's only heading and carries the headline; the section it labels sits beside it.
      heading = LazyHTML.query(document, "details#saved-reset-operation-bank-#{@identity}-details > summary#saved-reset-operation-heading-bank-#{@identity}")
      assert LazyHTML.text(heading) =~ "Saved reset"
      assert LazyHTML.text(heading) =~ headline
      assert Enum.empty?(LazyHTML.query(document, "h3, h4"))
      # One fact only: the latest reset is not labelled and its headline is not repeated under the summary.
      refute Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-latest']"))
      refute LazyHTML.text(document) =~ "Latest reset"
      assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-headline']"))
      # An applied reset has no unresolved caveat to show.
      assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-provider-outcome']"))
      refute Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-consumed-at']"))
      refute Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-deadline-at']"))
      refute Enum.empty?(LazyHTML.query(document, "button#saved-reset-status-refresh-bank-#{@identity}[phx-click='refresh_saved_reset_status'][phx-value-id='#{@identity}']"))
      refute Enum.empty?(LazyHTML.query(document, "[role='status'][aria-live='polite'][aria-atomic='true']"))
      assert Enum.empty?(LazyHTML.query(document, "[role='status'] dl"))
      refute html =~ "progressbar"
      refute html =~ "alert-warning"
    end
  end

  @tag :receipt_state_rendering
  test "a newer queued request and older confirmed account result remain separate" do
    operation = project(%{redemption: applied("confirmed_by_quota"), request_summary: %{open: %{state: :queued, requested_at: @now}, latest_terminal: nil}})
    html = receipt(operation)
    record_html("queued-old-confirmed", html)
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "[data-role='saved-reset-request']") |> LazyHTML.text() =~ "Request accepted"
    assert LazyHTML.query(document, "[data-role='saved-reset-latest']") |> LazyHTML.text() =~ "Quota confirmed"
    # Two facts are shown side by side, so the older one is labelled to stay distinct from the request.
    assert LazyHTML.query(document, "[data-role='saved-reset-latest']") |> LazyHTML.text() =~ "Latest reset"
    assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-request'] [data-role='saved-reset-consumed-at']"))
    assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-latest'] [data-role='saved-reset-requested-at']"))
  end

  @tag :receipt_state_rendering
  test "list and open bank for one identity have unique ids and local aria references" do
    operation = project(%{redemption: applied("consumed_pending_probe")})
    html = receipt(operation, :list) <> receipt(operation, :bank)
    record_html("list-bank", html)
    document = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(document, "section[data-role='saved-reset-operation']")) == 2
    ids = document |> LazyHTML.query("[id]") |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
    assert ids == Enum.uniq(ids)

    for surface <- [:list, :bank], attribute <- ["aria-labelledby", "aria-describedby"] do
      node = LazyHTML.query(document, "#saved-reset-operation-#{surface}-#{@identity}")

      references = LazyHTML.attribute(node, attribute)
      assert length(references) == 1

      # The bank section is labelled by the disclosure summary beside it, so its references resolve inside the whole disclosure, never in the other surface.
      owner = if surface == :bank, do: "#saved-reset-operation-bank-#{@identity}-details", else: "#saved-reset-operation-list-#{@identity}"

      for id <- references do
        assert Enum.count(LazyHTML.query(LazyHTML.query(document, owner), "##{id}")) == 1
      end
    end

    # The refresh explanation moved into a tooltip and a screen-reader paragraph; the button must still point at that paragraph.
    refresh = LazyHTML.query(document, "button#saved-reset-status-refresh-bank-#{@identity}")
    assert LazyHTML.attribute(refresh, "title") == ["Reads the recorded status. It does not contact the provider or start another redemption."]
    assert [description_id] = LazyHTML.attribute(refresh, "aria-describedby")
    assert LazyHTML.query(LazyHTML.query(document, "#saved-reset-operation-bank-#{@identity}-details"), "##{description_id}") |> LazyHTML.text() =~ "does not contact the provider or start another redemption"
  end

  @tag :receipt_state_rendering
  test "queued and processing manual requests carry no provider success claim" do
    for {state, summary} <- [queued: "Queued. Nothing has been sent to the provider yet.", processing: "Being processed."] do
      operation = project(%{request_summary: %{open: %{state: state, requested_at: @now, scheduled_at: DateTime.add(@now, 30)}, latest_terminal: nil}})
      html = receipt(operation)
      document = LazyHTML.from_fragment(html)
      assert LazyHTML.query(document, "summary#saved-reset-operation-heading-bank-#{@identity}") |> LazyHTML.text() =~ "Request accepted — #{state}"
      assert LazyHTML.query(document, "[data-role='saved-reset-request']") |> LazyHTML.text() =~ summary
      assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-latest']"))
      assert Enum.count(LazyHTML.query(document, "[data-role='saved-reset-requested-at'], [data-role='saved-reset-scheduled-at']")) == 2
      refute html =~ ~r/Reset applied|applied the reset/
      record_html("#{state}", html)
    end
  end

  @tag :receipt_state_rendering
  test "a completed request beside the latest receipt leaves only the receipt" do
    completed = %{open: nil, latest_terminal: %{state: :completed, requested_at: DateTime.add(@now, -60), scheduled_at: DateTime.add(@now, -60)}}
    html = %{redemption: applied("consumed_pending_probe"), request_summary: completed} |> project() |> receipt()
    record_html("completed-request-applied", html)
    document = LazyHTML.from_fragment(html)
    assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-request']"))
    refute LazyHTML.text(document) =~ "Request completed"
    refute LazyHTML.text(document) =~ "Latest reset"
    assert LazyHTML.query(document, "summary#saved-reset-operation-heading-bank-#{@identity}") |> LazyHTML.text() =~ "Reset applied — verifying quota"
    assert LazyHTML.query(document, "[data-role='saved-reset-latest']") |> LazyHTML.text() =~ "Waiting for a usage report to confirm the new quota."
    assert LazyHTML.query(document, "#saved-reset-operation-bank-#{@identity}-announcement") |> LazyHTML.text() |> String.trim() == "Reset applied — verifying quota"
  end

  @tag :receipt_state_rendering
  test "a request that ended without completing keeps its own line beside the latest receipt" do
    for {state, headline} <- [discarded: "Request did not complete", cancelled: "Request cancelled"] do
      ended = %{open: nil, latest_terminal: %{state: state, requested_at: DateTime.add(@now, -60), scheduled_at: DateTime.add(@now, -60)}}
      noop = %{"phase" => "consume_not_applied", "result" => %{"applied" => false, "code" => "no_credit"}}
      html = %{redemption: noop, request_summary: ended} |> project() |> receipt()
      record_html("ended-request-#{state}", html)
      document = LazyHTML.from_fragment(html)
      request = LazyHTML.query(document, "[data-role='saved-reset-request']") |> LazyHTML.text()
      assert request =~ "Request"
      assert request =~ headline
      assert request =~ "Check the latest reset before acting."
      refute request =~ "without a recorded result"
      assert Enum.count(LazyHTML.query(document, "[data-role='saved-reset-request'] [data-role='saved-reset-requested-at']")) == 1
      assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-request'] [data-role='saved-reset-scheduled-at']"))
      latest = LazyHTML.query(document, "[data-role='saved-reset-latest']") |> LazyHTML.text()
      assert latest =~ "Latest reset"
      assert latest =~ "No saved reset was available"
    end
  end

  @tag :compact_list_presentation
  test "the list row names a passed deadline like the detail does" do
    passed = Map.put(applied("consumed_pending_probe"), "deadline_at", DateTime.to_iso8601(DateTime.add(@now, -1)))
    list = %{redemption: passed} |> project() |> receipt(:list) |> LazyHTML.from_fragment()
    assert LazyHTML.query(list, "[data-role='saved-reset-headline']") |> LazyHTML.text() =~ "Deadline passed — checking quota"
    bank = %{redemption: passed} |> project() |> receipt(:bank) |> LazyHTML.from_fragment()
    assert LazyHTML.query(bank, "summary#saved-reset-operation-heading-bank-#{@identity}") |> LazyHTML.text() =~ "Deadline passed — checking quota"
  end

  @tag :receipt_ambiguity_and_no_fake_success
  test "unexpected states and synthetic private metadata cannot enter status attributes" do
    operation = project(%{request_summary: :unavailable}) |> Map.merge(%{provider_outcome: :synthetic_private_outcome, verification: :synthetic_private_verification, attempt_id: "synthetic-private-attempt", job_args: "synthetic-private-job", raw_error: "synthetic-private-error"})
    html = receipt(operation)
    document = LazyHTML.from_fragment(html)
    refute Enum.empty?(LazyHTML.query(document, "[data-provider-outcome='unknown'][data-verification-state='unknown']"))
    for private <- ["synthetic_private_outcome", "synthetic_private_verification", "synthetic-private-attempt", "synthetic-private-job", "synthetic-private-error"], do: refute(html =~ private)
    assert Enum.empty?(LazyHTML.query(document, "[data-attempt-id], [data-job-args], [data-refresh-cursor], .animate-spin, [role='progressbar']"))
  end

  @tag :receipt_ambiguity_and_no_fake_success
  test "every uncertain, no-op, paused, stopped and legacy state stays truthful" do
    cases = [
      {%{redemption: %{"phase" => "consuming", "started_at" => DateTime.to_iso8601(DateTime.add(@now, -1))}}, "Reset request in progress"},
      {%{redemption: %{"phase" => "consuming", "started_at" => "2020-01-01T00:00:00Z"}}, "Reset outcome not confirmed"},
      {%{redemption: %{"phase" => "consuming", "result" => %{"applied" => true, "code" => "synthetic-private-code"}}}, "Reset outcome not confirmed"},
      {%{redemption: %{"phase" => "consume_not_applied", "result" => %{"applied" => false, "code" => "no_credit"}}}, "No saved reset was available"},
      {%{redemption: %{"phase" => "consume_not_applied", "result" => %{"applied" => false, "code" => "nothing_to_reset"}}}, "Nothing needed resetting"},
      {%{redemption: %{"phase" => "consume_not_applied", "result" => %{"applied" => false, "code" => "consume_not_applied"}, "provider_replay" => %{"version" => 1, "provider_dispatches" => 0}}}, "Reset was not applied"},
      {%{redemption: applied("reblocked")}, "Quota is still unavailable"},
      {%{redemption: applied("expired")}, "Quota confirmation timed out"},
      {%{redemption: Map.put(applied("consumed_pending_probe"), "deadline_at", DateTime.to_iso8601(DateTime.add(@now, -1)))}, "Deadline passed — checking quota"},
      {%{redemption: %{"phase" => "confirmed_by_quota"}}, "Quota confirmed"},
      {%{redemption: applied("consumed_pending_probe"), usage_poll_pause: %{paused_until: DateTime.add(@now, 60)}}, "Quota checks are delayed"},
      {%{redemption: applied("consumed_pending_probe"), usage_poll_pause: :unavailable}, "Quota checks are delayed"},
      {%{redemption: applied("consumed_pending_probe"), view_paused?: true}, "Live updates paused"},
      {%{redemption: applied("consumed_pending_probe"), view_connected?: false}, "Live updates disconnected"},
      {%{request_summary: %{open: nil, latest_terminal: %{state: :stopped, requested_at: @now}}}, "Request stopped"},
      {%{request_summary: :unavailable}, "Request status unavailable"}
    ]

    for {context, headline} <- cases do
      html = context |> project() |> receipt()
      record_html("failure-#{Enum.find_index(cases, &(&1 == {context, headline}))}", html)
      document = LazyHTML.from_fragment(html)
      assert LazyHTML.text(document) =~ headline
      refute html =~ "synthetic-private-code"
      refute html =~ "Not reported"
      refute html =~ "Routing ready"
      refute html =~ "redeem_saved_reset"
      refute html =~ "Retry"
      assert Enum.empty?(LazyHTML.query(document, "[role='status'] [data-role='saved-reset-pause-until']"))
    end
  end

  @tag :receipt_ambiguity_and_no_fake_success
  test "an unresolved outcome keeps its redemption warning visible under every observation override" do
    unresolved = %{"phase" => "consuming", "started_at" => "2020-01-01T00:00:00Z"}

    for {name, observation} <- [paused: %{view_paused?: true}, disconnected: %{view_connected?: false}, polling_delayed: %{usage_poll_pause: :unavailable}] do
      document = %{redemption: unresolved} |> Map.merge(observation) |> project() |> receipt() |> LazyHTML.from_fragment()
      warning = LazyHTML.query(document, "[data-role='saved-reset-latest'] [data-role='saved-reset-provider-outcome']")
      assert LazyHTML.text(warning) =~ "Don't redeem again until this resolves.", "#{name}"
      # The override replaces the body headline, while the disclosure summary keeps naming the unresolved outcome.
      assert LazyHTML.query(document, "summary#saved-reset-operation-heading-bank-#{@identity}") |> LazyHTML.text() =~ "Reset outcome not confirmed", "#{name}"
    end
  end

  @tag :receipt_state_rendering
  test "the hidden connection notice repeats the disconnected receipt copy and names a continuing reset only while one is open" do
    disconnected = project(%{redemption: applied("consumed_pending_probe"), view_connected?: false})
    assert disconnected.open?
    in_flight = render_component(&Components.saved_reset_connection_notice/1, %{id: "saved-reset-connection-sample", in_flight: true}) |> LazyHTML.from_fragment()
    assert LazyHTML.query(in_flight, "#saved-reset-connection-sample[data-saved-reset-connection-notice][hidden]") |> LazyHTML.text() |> String.trim() == "#{disconnected.headline}. #{disconnected.summary}"

    # With nothing open the notice drops the continuing-reset sentence and keeps the rest of the receipt copy.
    refute project(%{redemption: applied("confirmed_by_quota")}).open?
    idle = render_component(&Components.saved_reset_connection_notice/1, %{id: "saved-reset-connection-sample"}) |> LazyHTML.from_fragment()
    idle_text = LazyHTML.query(idle, "#saved-reset-connection-sample[data-saved-reset-connection-notice][hidden]") |> LazyHTML.text() |> String.trim()
    assert idle_text == "#{disconnected.headline}. #{String.replace(disconnected.summary, "The reset continues. ", "")}"
    refute idle_text =~ "The reset continues"
  end

  @tag :receipt_state_rendering
  test "the connection notice keeps its type scale and takes a container gutter only from its caller" do
    gutter = "border-b border-base-300 px-5 py-3"
    classes = fn assigns -> render_component(&Components.saved_reset_connection_notice/1, Map.put(assigns, :id, "saved-reset-connection-sample")) |> LazyHTML.from_fragment() |> LazyHTML.query("#saved-reset-connection-sample[data-saved-reset-connection-notice][hidden]") |> LazyHTML.attribute("class") |> List.first() |> String.split() end

    assert classes.(%{}) == ["text-xs", "leading-5", "text-base-content/70"]
    assert classes.(%{class: gutter}) == ["text-xs", "leading-5", "text-base-content/70" | String.split(gutter)]
  end

  @tag :receipt_ambiguity_and_no_fake_success
  test "queued-only request shows pause and disconnect observations without an account receipt" do
    for observation <- [%{view_paused?: true}, %{view_connected?: false}, %{usage_poll_pause: :unavailable}] do
      operation = project(Map.put(observation, :request_summary, %{open: %{state: :queued, requested_at: @now}, latest_terminal: nil}))
      html = receipt(operation)
      document = LazyHTML.from_fragment(html)
      assert LazyHTML.text(document) =~ operation.headline
      assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-latest']"))
      record_html("queued-#{operation.headline}", html)
    end
  end

  @tag :receipt_ambiguity_and_no_fake_success
  test "timestamps, live announcement and private projection fields remain separate" do
    operation = project(%{redemption: applied("consumed_pending_probe"), last_checked_at: @now}) |> Map.put(:saved_reset_refresh_cursor, "synthetic-private-cursor")
    changed_clock = Map.put(operation, :last_checked_at, "October 5, 2026 at 12:01 UTC")
    before_document = operation |> receipt() |> LazyHTML.from_fragment()
    after_document = changed_clock |> receipt() |> LazyHTML.from_fragment()
    assert LazyHTML.query(before_document, "[role='status']") |> LazyHTML.text() |> String.trim() == LazyHTML.query(after_document, "[role='status']") |> LazyHTML.text()
    refute receipt(operation) =~ "synthetic-private-cursor"
    refute Enum.empty?(LazyHTML.query(before_document, "[data-role='saved-reset-last-checked-at']"))
    assert Enum.empty?(LazyHTML.query(before_document, "[role='status'] [data-role='saved-reset-last-checked-at']"))
  end

  @tag :receipt_ambiguity_and_no_fake_success
  test "empty and consuming receipts omit absent future facts and require a closed surface" do
    empty = project(%{}) |> receipt()
    assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(empty), "section"))
    consuming = project(%{redemption: %{"phase" => "consuming", "started_at" => DateTime.to_iso8601(@now)}}) |> receipt()
    assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(consuming), "[data-role='saved-reset-consumed-at'], [data-role='saved-reset-deadline-at']"))
    assert_raise ArgumentError, fn -> receipt(project(%{}), :invalid_surface) end
  end

  @tag :receipt_state_rendering
  test "confirmation uses approved copy and distinct existing controls without owning editable form fields" do
    html = render_component(&Components.saved_reset_confirmation/1, %{identity_id: @identity, surface: :bank, id: "saved-reset-redemption-confirmation", confirm_id: "saved-reset-redemption-confirm", cancel_id: "saved-reset-redemption-cancel"})
    document = LazyHTML.from_fragment(html)
    record_html("confirmation", html)
    assert LazyHTML.text(document) =~ "Redeem one saved reset for this account? The provider may apply it before quota checks finish. Verification can take a few minutes. You can leave this view and return to check the status."
    assert LazyHTML.query(document, "#saved-reset-redemption-confirm[phx-click='redeem_saved_reset'][type='button']") |> LazyHTML.text() |> String.trim() == "Redeem one reset"
    assert LazyHTML.query(document, "#saved-reset-redemption-cancel[phx-click='cancel_saved_reset_redemption'][type='button']") |> LazyHTML.text() |> String.trim() == "Keep resets in bank"
    assert Enum.empty?(LazyHTML.query(document, "form, input, select"))
  end

  @tag :receipt_state_rendering
  test "renders current conditional readiness without recalculating it" do
    readiness = %{label: "Conditional availability", reason: "Availability depends on the model and transport.", routing_ready_now?: true}
    operation = project(%{redemption: applied("confirmed_by_upstream"), serving_readiness: readiness})
    html = receipt(operation)
    document = LazyHTML.from_fragment(html)
    line = LazyHTML.query(document, "[data-role='saved-reset-serving-readiness']")
    assert LazyHTML.text(line) =~ "Routing: Conditional availability"
    assert LazyHTML.attribute(line, "title") == [readiness.reason]
    refute html =~ "Routing ready"
    refute html =~ "routing_ready_now"
    # The cockpit shows the same readiness in its own routing lanes, so its receipt does not repeat the line.
    assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(receipt(operation, :cockpit)), "[data-role='saved-reset-serving-readiness']"))
  end

  @tag :receipt_state_rendering
  test "an account that cannot route shows its routing reason on the bank receipt" do
    readiness = %{label: "Banked-reset recovery pending", reason: "Waiting for fresh included-quota data to confirm the reset.", routing_ready_now?: false}
    document = project(%{redemption: applied("consumed_pending_probe"), serving_readiness: readiness}) |> receipt(:bank) |> LazyHTML.from_fragment()
    line = LazyHTML.query(document, "[data-role='saved-reset-serving-readiness']")
    assert LazyHTML.text(line) =~ "Routing: Banked-reset recovery pending"
    # The reason is printed in the line, visible to everyone; the tooltip it used to live in is unchanged.
    assert LazyHTML.text(LazyHTML.query(line, "span[data-role='saved-reset-serving-reason']")) == readiness.reason
    assert Enum.count(LazyHTML.query(line, "span.block[data-role='saved-reset-serving-reason']")) == 1
    assert Enum.empty?(LazyHTML.query(line, "span.sr-only[data-role='saved-reset-serving-reason']"))
    assert LazyHTML.attribute(line, "title") == [readiness.reason]
  end

  @tag :receipt_state_rendering
  test "an account that routes keeps its reason for assistive technology only" do
    readiness = %{label: "Routing ready", reason: "Identity, assignment and quota are ready for routing.", routing_ready_now?: true}
    document = project(%{redemption: applied("confirmed_by_quota"), serving_readiness: readiness}) |> receipt(:bank) |> LazyHTML.from_fragment()
    line = LazyHTML.query(document, "[data-role='saved-reset-serving-readiness']")
    assert LazyHTML.text(line) =~ "Routing: Routing ready"
    assert LazyHTML.text(LazyHTML.query(line, "span[data-role='saved-reset-serving-reason']")) == readiness.reason
    assert Enum.count(LazyHTML.query(line, "span.sr-only[data-role='saved-reset-serving-reason']")) == 1
    assert Enum.empty?(LazyHTML.query(line, "span.block[data-role='saved-reset-serving-reason']"))
    assert LazyHTML.attribute(line, "title") == [readiness.reason]
  end

  for surface <- [:cockpit, :list], routing_ready_now? <- [true, false] do
    @tag :receipt_state_rendering
    test "the #{surface} surface carries no routing line or reason when routing_ready_now? is #{routing_ready_now?}" do
      readiness = %{label: "Current readiness", reason: "Existing readiness fact", routing_ready_now?: unquote(routing_ready_now?)}
      document = project(%{redemption: applied("consumed_pending_probe"), serving_readiness: readiness}) |> receipt(unquote(surface)) |> LazyHTML.from_fragment()
      # The receipt itself renders, so the missing line is not an empty surface.
      assert Enum.count(LazyHTML.query(document, "[data-role='saved-reset-operation']")) == 1
      assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-serving-readiness'], [data-role='saved-reset-serving-reason']"))
      refute LazyHTML.text(document) =~ readiness.reason
    end
  end

  @tag :compact_list_presentation
  test "normal historical receipts add no list status even when updates are paused" do
    readiness = %{label: "Ready", reason: "Current quota is available.", routing_ready_now?: true}

    for context <- [
          %{},
          %{view_paused?: true},
          %{redemption: applied("confirmed_by_quota")},
          %{redemption: applied("confirmed_by_quota"), view_paused?: true},
          %{redemption: applied("confirmed_by_quota"), view_connected?: false},
          %{redemption: %{"phase" => "confirmed_by_quota"}, view_paused?: true},
          %{redemption: applied("confirmed_by_upstream"), view_paused?: true},
          %{request_summary: :unavailable, view_paused?: true},
          %{request_summary: %{open: nil, latest_terminal: %{state: :stopped, requested_at: @now}}, redemption: applied("confirmed_by_quota"), view_paused?: true},
          %{redemption: %{"phase" => "consume_not_applied", "result" => %{"applied" => false, "code" => "no_credit"}}}
        ] do
      operation = context |> Map.put(:serving_readiness, readiness) |> project()
      html = receipt(operation, :list)
      assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(html), "[data-role='saved-reset-operation']"))
      record_html("normal-#{length(Map.keys(context))}-#{operation.headline}", "<main data-evidence-host>#{html}</main>")

      if operation.show_latest_receipt? do
        detail = receipt(operation, :bank)
        document = LazyHTML.from_fragment(detail)
        assert Enum.count(LazyHTML.query(document, "details:not([open]) [data-role='saved-reset-latest']")) == 1
        latest = LazyHTML.query(document, "[data-role='saved-reset-latest']") |> LazyHTML.text()
        assert latest =~ operation.summary
        # The caveat line renders exactly when the projection has a detail for it.
        assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-provider-outcome']")) == is_nil(operation.detail)
        if operation.detail, do: assert(latest =~ operation.detail)
        record_html("historical-bank-#{operation.headline}", detail)
      end
    end
  end

  @tag :compact_list_presentation
  test "active and unresolved list status is a single compact row with the safe dialog action" do
    contexts = [
      %{request_summary: %{open: %{state: :queued, requested_at: @now}, latest_terminal: nil}},
      %{request_summary: %{open: %{state: :processing, requested_at: @now}, latest_terminal: nil}, redemption: applied("confirmed_by_quota")},
      %{redemption: applied("consumed_pending_probe")},
      %{redemption: applied("consumed_pending_probe"), view_paused?: true},
      %{redemption: applied("confirmed_by_upstream")},
      %{redemption: %{"phase" => "legacy_unknown"}},
      %{redemption: %{"phase" => "consuming", "started_at" => "2020-01-01T00:00:00Z"}}
    ]

    for {context, index} <- Enum.with_index(contexts) do
      operation = project(context)
      html = receipt(operation, :list)
      document = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(document, "[data-role='saved-reset-operation'][data-presentation='compact']")) == 1
      assert Enum.count(LazyHTML.query(document, "[data-role='saved-reset-headline']")) == 1
      assert Enum.count(LazyHTML.query(document, "button[data-role='saved-reset-view-status'][type='button'][phx-value-id='#{@identity}']")) == 1
      assert LazyHTML.query(document, "[data-role='saved-reset-view-status']") |> LazyHTML.text() |> String.trim() == "View status"
      assert Enum.empty?(LazyHTML.query(document, "dl, [data-role='saved-reset-serving-readiness'], [data-role='saved-reset-latest'], [data-role='saved-reset-observation']"))
      refute html =~ "border-base-300"
      refute html =~ "Refresh reads"
      record_html("compact-list-#{index}", html)
    end
  end

  @tag :compact_list_presentation
  test "terminal recovery attention follows current readiness and all detail surfaces keep their own disclosure" do
    for phase <- ["reblocked", "expired"], ready? <- [true, false] do
      operation = project(%{redemption: applied(phase), serving_readiness: %{label: "Current readiness", reason: "Existing readiness fact", routing_ready_now?: ready?}})
      document = operation |> receipt(:list) |> LazyHTML.from_fragment()
      assert Enum.empty?(LazyHTML.query(document, "[data-role='saved-reset-operation']")) == ready?
      record_html("terminal-list-#{phase}-#{ready?}", "<main data-evidence-host>#{receipt(operation, :list)}</main>")
    end

    for surface <- [:bank, :cockpit] do
      operation = project(%{redemption: applied("consumed_pending_probe")})
      document = operation |> receipt(surface) |> LazyHTML.from_fragment()
      assert Enum.count(LazyHTML.query(document, "details#saved-reset-operation-#{surface}-#{@identity}-details[open][data-preserve-open]")) == 1
      assert Enum.count(LazyHTML.query(document, "#saved-reset-status-refresh-#{surface}-#{@identity}[data-saved-reset-action='status-refresh'][data-server-disabled='false']")) == 1
      record_html("active-detail-#{surface}", receipt(operation, surface))
    end
  end

  defp record_html(name, html) do
    if directory = System.get_env("SAVED_RESET_COMPONENT_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      filename = name |> String.downcase() |> String.replace(~r/[^a-z0-9-]+/, "-")
      File.write!(Path.join(directory, "#{filename}.html"), html)
    end
  end

  defp receipt(operation, surface \\ :bank), do: render_component(&SavedResetOperation.saved_reset_operation/1, %{operation: operation, identity_id: @identity, surface: surface})
  defp project(context), do: Projection.project(Map.merge(%{snapshot_at: @now, datetime_preferences: DateTimeDisplay.preferences_for_user(nil)}, context))
  defp applied(phase), do: %{"phase" => phase, "started_at" => DateTime.to_iso8601(DateTime.add(@now, -20)), "consumed_at" => DateTime.to_iso8601(DateTime.add(@now, -10)), "deadline_at" => DateTime.to_iso8601(DateTime.add(@now, 180)), "result" => %{"applied" => true, "code" => "reset"}}
end
