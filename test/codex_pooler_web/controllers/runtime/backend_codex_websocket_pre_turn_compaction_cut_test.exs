defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketPreTurnCompactionCutTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  alias CodexPoolerWeb.Runtime.PreTurnCompactionCutScenario, as: Scenario

  # A client cut during an admitted anchored native compaction (findings#206
  # row 206-310). The released client (Codex 0.156.1, observed on the wire in
  # Full and Lite) sends its pre-turn compaction anchored on the previous
  # turn's response, on that turn's connection, with the NEW turn's id and
  # only the `compaction_trigger`; the owner admits it on the first send since
  # `e48cde2f9`. A mid-turn compaction is anchored the same way under its own
  # turn's id and was admitted before, and so is the manual `/compact` of a
  # standalone turn whose anchor resolves to the session (production row
  # `0fd0b900`, Codex Desktop). When the connection is cut, the client
  # drops it and resends the same compaction as full history on a new
  # connection (`compact_remote_v2.rs` retry loop: two websocket retries, then
  # HTTPS). The admitted compaction held no durable claim, so with owner
  # forwarding off that resend found its claim free: after a billed completion
  # it was served and billed again, and while the cut predecessor was still
  # live it hit the active-turn index and left an accepted row behind
  # (`500 websocket_response_task_failed`, then `409 duplicate_turn`). Both
  # forms now derive one compaction claim (findings#206 row 206-310). Every arm
  # drives the released client's whole retry (P69 wire probe): two websocket
  # resends on new connections, then `POST /responses` over SSE with the same
  # body and two HTTP retries, after which the turn fails. A cut after
  # upstream output or after a billed completion used to be refused `409`
  # twice and then bought again, unchained, by that HTTPS fallback; the client
  # resends a compaction only when it did not complete it, so the resend is
  # now the predecessor's successor, one charge per request (rows 206-330 and
  # 206-332). The HTTPS fallback of a compaction whose websocket resends met a
  # live predecessor derives the websocket claim and is chained the same way.
  # Frames keep the released client's key sets; identifiers, prompt text and
  # reply frames are synthetic. One node, owner forwarding on and off; the
  # resend is sent once the predecessor has settled (the released client
  # retries after about 200 ms), except in the `unobserved_cut` arm, where the
  # Pooler has not seen the cut when the websocket resends arrive. The `peer`
  # arms (the session's owner on a second VM) live in
  # `backend_codex_websocket_pre_turn_compaction_cut_peer_test.exs`; the
  # scenario itself is `PreTurnCompactionCutScenario`.
  @arms for mode <- ["full", "lite"], shape <- [:pre_turn, :mid_turn, :standalone_turn], mode == "full" or shape == :pre_turn, do: {mode, shape}

  for {mode, shape} <- @arms, topology <- [:forwarded, :direct], cut <- [:no_cut, :before_output, :after_output, :after_completion, :unobserved_cut] do
    @tag mode: mode, shape: shape, topology: topology, cut: cut
    test "#{mode} #{shape} #{topology} admitted compaction #{cut}: the released client's retries buy the compaction once per request and the turn completes",
         %{mode: mode, shape: shape, topology: topology, cut: cut} do
      assert Scenario.run_scenario(mode, shape, topology, cut) == Scenario.expected(cut, topology)
    end
  end

  # The released client (Codex 0.156.1) retries a failed compaction stream on a
  # new connection about 200 ms after the failure and again about 400 ms later,
  # then falls back to HTTPS for the rest of its session. The Pooler's cleanup
  # of the closed connection (its owner detach after a 250 ms drain, which the
  # socket waits on for 100 ms only) can finish after that. Here it is held at
  # its first query until the retries resolved, so the first websocket retry
  # inherits, at its attach, a compaction whose socket already closed: with
  # owner forwarding it takes that compaction over as its own close would and
  # is served, where it used to be refused `409 duplicate_turn` and only the
  # second retry was served (findings#206 row 206-436). In `observed_cut_exited`
  # a first new connection inherits the compaction and drops before sending
  # anything, its cleanup held too, and the owner has handled its exit when the
  # retry attaches. The `unobserved_cut` arms above keep the refusal: there the
  # compaction was handed on from a connection the Pooler has not seen close.
  # With owner forwarding off (`direct_committed`: the direct topology on
  # committed rows, so the held cleanup's transaction stalls no other
  # connection; Full only, as the peer arms, since the Lite override commits an
  # owner session) the retry carries the compaction's own claim; its claim waits,
  # bounded, for the running request to settle, and the held cleanup is
  # released once it waits. It used to be refused at once, twice, and the
  # compaction was bought over HTTPS.
  for {mode, shape} <- [{"full", :pre_turn}, {"lite", :pre_turn}, {"full", :mid_turn}],
      topology <- [:forwarded, :direct_committed],
      cut <- [:observed_cut, :observed_cut_exited],
      mode == "full" or topology != :direct_committed,
      shape == :pre_turn or cut == :observed_cut,
      topology != :direct_committed or cut == :observed_cut do
    @tag mode: mode, shape: shape, topology: topology, cut: cut
    test "#{mode} #{shape} #{topology} admitted compaction #{cut} with the closed socket's cleanup held: the released client's first websocket retry is served",
         %{mode: mode, shape: shape, topology: topology, cut: cut} do
      assert Scenario.run_scenario(mode, shape, topology, cut) == Scenario.expected(cut, topology)
    end
  end

  # The released client sends its compaction the moment the previous turn's
  # `response.completed` arrives, and the Pooler's response task for that turn
  # may still be settling it: the socket then queues the compaction and
  # dispatches it when the task ends, without the owner preflight that records
  # the turn it submits, and the owner could not key a compaction body (the
  # upstream body carries no turn metadata). It ran as an `:unknown` turn that
  # no same-turn check could match, seen on the peer owner in the observed
  # arms (findings#206 row 206-455). Here the previous turn's response task is
  # held after its settlement until the compaction is queued. The owner keys
  # the queued compaction from its admission binding, and the released
  # client's resends while it runs are never a second provider generation:
  # the owner runs one turn at a time and refuses a resend until the running
  # compaction settled (or takes it over from a socket that already closed),
  # and without owner forwarding the compaction claim refuses it.
  for {mode, shape} <- [{"full", :pre_turn}, {"lite", :pre_turn}, {"full", :mid_turn}],
      {topology, cut} <- [{:forwarded, :unobserved_cut}, {:direct, :unobserved_cut}, {:forwarded, :observed_cut}, {:direct_committed, :observed_cut}],
      mode == "full" or topology != :direct_committed do
    @tag mode: mode, shape: shape, topology: topology, cut: cut, dispatch: :queued
    test "#{mode} #{shape} #{topology} compaction queued behind the settling turn, #{cut}: the owner keys it and no resend is a second generation while it runs",
         %{mode: mode, shape: shape, topology: topology, cut: cut} do
      assert Scenario.run_scenario(mode, shape, topology, cut, :queued) == Scenario.expected(cut, topology)
    end
  end
end
