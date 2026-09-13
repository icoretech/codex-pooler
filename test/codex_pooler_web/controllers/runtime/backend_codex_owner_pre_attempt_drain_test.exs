defmodule CodexPoolerWeb.Runtime.BackendCodexOwnerPreAttemptDrainTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, PreAttemptRelease, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Gateway.Websocket.DownstreamSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @budget 15_000
  @moduletag capture_log: true

  defmodule UnsupportedOwner do
    def connected_app_nodes, do: [:"owner@sample-app"]
    def app_node?(_node), do: true
    def call_owner(_node, _module, _function, _args, _timeout), do: {:error, :owner_unavailable}
  end

  for phase <- [:claim, :reservation, :attempt] do
    test "owner drain after #{phase} commit closes the exact admitted turn" do
      assert_drain_phase(unquote(phase))
    end
  end

  for owner_mode <- [:unsupported, :missing] do
    test "#{owner_mode} owner admission rejects before durable claim" do
      assert_owner_unavailable(unquote(owner_mode))
    end
  end

  defp assert_owner_unavailable(mode) do
    {setup, upstream, state} = fixture()
    remote = :"owner@sample-app"
    session = %{state.codex_session | owner_instance_id: Atom.to_string(remote)}
    client = if mode == :unsupported, do: UnsupportedOwner, else: nil
    owner_opts = if client, do: [node_client: client], else: [app_node_names: []]

    state = %{
      state
      | codex_session: session,
        opts: Map.put(state.opts, :websocket_owner_forwarder_opts, owner_opts)
    }

    frame =
      setup
      |> payload()
      |> CodexPooler.JSON.decode!()
      |> Map.delete("client_metadata")
      |> CodexPooler.JSON.encode!()

    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:codex_response_done, task, result}, @budget

    assert {:push, _, state} =
             CodexResponsesSocket.handle_info({:codex_response_done, task, result}, state)

    assert inspect(result) =~ "owner_unavailable"
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    assert FakeUpstream.count(upstream) == 0
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  test "owner-bound admission rejects missing malformed and replacement authority" do
    {setup, upstream, state} = fixture()
    attach_commit_barrier(:reservation)
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload(setup), [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert_receive {:direct_request_cleanup, ^task, _ref, receipt}, @budget
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)

    # The suite runs at :warning; the refused-clause line is an :info the
    # production default level does emit, so raise it for this module only.
    :ok = Logger.put_module_level(Interruption, :info)
    on_exit(fn -> Logger.delete_module_level(Interruption) end)

    for {invalid, refused_clause} <- [
          {Map.delete(receipt, :owner_binding), "owner_forwarded_request_without_binding"},
          {%{receipt | owner_binding: nil}, "owner_forwarded_request_without_binding"},
          {%{receipt | owner_binding: %{}}, "owner_binding_malformed"},
          {put_in(receipt.owner_binding.owner_lease_token, Ecto.UUID.generate()),
           "session_owner_lease_token"},
          {put_in(
             receipt.owner_binding.downstream_epoch,
             receipt.owner_binding.downstream_epoch + 1
           ), "metadata_downstream_epoch"}
        ] do
      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = DirectCleanup.interrupt(invalid, "owner_drained")
        end)

      # A gate that refuses must say which clause refused; a silent :ok is
      # what made this defect only findable from row shapes.
      assert logs =~ "websocket direct interrupt gate not matched"
      assert logs =~ "refused_clause=#{refused_clause}"
      assert logs =~ "request_id=#{request.id}"
      assert Repo.reload!(request) == request
    end

    assert :ok = WebsocketOwnerSession.drain_owner(state.websocket_owner_pid)
    assert_terminal(request, :reservation)
    assert FakeUpstream.count(upstream) == 0
  end

  test "pending task shutdown preserves drain reason through owner monitor cleanup" do
    {setup, _upstream, state} = fixture()
    attach_commit_barrier(:reservation)
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload(setup), [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    context = Map.fetch!(state.direct_cleanup_contexts, task)
    assert :ok = DirectCleanup.cancel_pending(context, "owner_drained")
    assert_terminal(request, :reservation)
    owner = state.websocket_owner_pid
    :sys.get_state(owner)
    assert :sys.get_state(owner).pending_admissions == %{}
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  test "socket cleanup cannot replace a marked owner drain reason after task death" do
    {setup, _upstream, state} = fixture()
    attach_commit_barrier(:reservation)
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload(setup), [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    context = Map.fetch!(state.direct_cleanup_contexts, task)
    owner = state.websocket_owner_pid
    :ok = :sys.suspend(owner)
    on_exit(fn -> if Process.alive?(owner), do: :sys.resume(owner) end)
    :ok = ActivityRegistry.mark_direct_cleanup_reason(context, "owner_drained")
    Process.exit(task, :kill)
    assert :ok = DirectCleanup.cancel(context, "client_disconnected")
    assert_terminal(request, :reservation)
    :ok = :sys.resume(owner)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  # Boundary: the `interrupt_turn!` no-active-attempt branch releases the
  # reservation and writes NO marker, even handed the strongest evidence a
  # caller could carry -- the owner triple and the drain reason that the
  # deleted `mark_verified_pre_attempt_drain/4` used to accept
  # (icoretech/codex-pooler-findings#178).
  #
  # This is the regression that fails the moment a second marker producer is
  # reintroduced on this branch. The marker a client resend actually reads is
  # written by the receipt path, `interrupt_direct_request/2`, and is covered
  # end to end -- real drain, real predicate, nothing stamped -- in
  # `backend_codex_pre_attempt_drain_resend_test.exs`.
  #
  # `drain_opts/3` is a *dispatch* builder (`DownstreamSession.response_options/2`).
  # The one interrupt caller on this tree that builds the same triple,
  # `CodexResponsesSocket`'s direct-response-task fallback, passes the socket's
  # connection-level request id as the turn selector, and a native websocket
  # request's `correlation_id` is its claim key, so that caller selects no turn
  # at all. The triple is supplied explicitly here so the branch is entered
  # with more authority than any real caller has, and still writes nothing.
  test "interrupt_turn route never marks a pre-attempt drain even given the owner triple" do
    {setup, upstream, state} = fixture()
    attach_commit_barrier(:reservation)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in({untagged_payload(setup), [opcode: :text]}, state)

    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert request.status == "in_progress"
    assert %{status: "in_progress"} = Repo.get_by!(CodexTurn, request_id: request.id)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
    assert ledger_kinds(request) == ["reservation"]

    # The provenance the deleted gate checked really is present: this is not a
    # request that would have failed the gate on its own metadata.
    assert is_map(request.request_metadata["websocket_owner_forwarding"])
    opts = drain_opts(state, request)

    assert opts.transport.websocket_owner.owner_instance_id ==
             state.codex_session.owner_instance_id

    assert opts.transport.websocket_owner.lease_token == state.codex_session.owner_lease_token
    assert is_integer(opts.transport.websocket_owner.downstream_epoch)

    assert {:ok, %{interrupted_turn_count: 1}} =
             Websocket.interrupt_codex_turn(state.codex_session, opts)

    reloaded = Repo.reload!(request)
    refute Map.has_key?(reloaded.request_metadata, "websocket_pre_attempt_drain")
    assert %{status: "failed", last_error_code: "owner_drained"} = reloaded
    assert ledger_kinds(request) == ["release", "reservation"]
    assert release_entry(request).details["release_reason"] == "owner_drained"
    assert FakeUpstream.count(upstream) == 0
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  # Boundary: a caller that DOES have an attempt row cannot reach the
  # pre-attempt branch at all, however much owner evidence it supplies. The
  # settlement proves branch 2 ran instead.
  test "interrupt_turn route with an attempt row cannot enter the pre-attempt branch" do
    {setup, upstream, state} = fixture()
    attach_commit_barrier(:attempt)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in({untagged_payload(setup), [opcode: :text]}, state)

    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1
    assert ledger_kinds(request) == ["reservation"]

    assert {:ok, %{interrupted_turn_count: 1}} =
             Websocket.interrupt_codex_turn(state.codex_session, drain_opts(state, request))

    reloaded = Repo.reload!(request)
    refute Map.has_key?(reloaded.request_metadata, "websocket_pre_attempt_drain")
    assert %{status: "failed", last_error_code: "owner_drained"} = reloaded
    # A settlement is the discriminating fact: only the attempted branch writes
    # one, so the pre-attempt branch demonstrably did not run.
    assert ledger_kinds(request) == ["release", "reservation", "settlement"]
    assert FakeUpstream.count(upstream) == 0

    # The response task is still parked on the attempt-commit barrier and this
    # test interrupts the turn out of band rather than draining the owner, so
    # nothing will ever release it. End it explicitly and prove it is gone
    # before teardown, instead of letting `terminate/2` spend its whole drain
    # budget waiting for a task that cannot finish.
    monitor = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, @budget
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  # Boundary: a real cleanup caller. The expired-owner sweeper
  # (`RuntimeCleanup.cleanup_expired_runtime_state/1`, the production Oban
  # path) reaches the same branch carrying only a lease token, and must still
  # give the reservation back while writing no marker. Nothing here is
  # hand-built: the request, turn, reservation, options and interrupt all come
  # from production code. Only the two clock columns that decide whether a
  # lease has expired are moved into the past, which is what waiting would do.
  test "the expired-owner sweeper releases a pre-attempt reservation without marking it" do
    {setup, upstream, state} = fixture()
    attach_commit_barrier(:reservation)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in({untagged_payload(setup), [opcode: :text]}, state)

    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert %{status: "in_progress"} = Repo.get_by!(CodexTurn, request_id: request.id)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
    assert ledger_kinds(request) == ["reservation"]

    expire_owner_lease!(state.codex_session.id)

    assert {:ok, %{expired_owner_sessions_recovered: 1}} =
             RuntimeCleanup.cleanup_expired_runtime_state()

    reloaded = Repo.reload!(request)
    refute Map.has_key?(reloaded.request_metadata, "websocket_pre_attempt_drain")
    assert %{status: "failed", last_error_code: "owner_unavailable"} = reloaded
    assert ledger_kinds(request) == ["release", "reservation"]
    assert release_entry(request).details["release_reason"] == "owner_unavailable"

    assert %{status: "interrupted", error_code: "owner_unavailable"} =
             Repo.get_by!(CodexTurn, request_id: request.id)

    assert FakeUpstream.count(upstream) == 0
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  # The same branch is reason-agnostic. An owner whose state is unknown must
  # get its reservation back without ever advertising a safe client resend.
  test "interrupt_turn route releases an owner_crashed pre-attempt drain without marking it" do
    {setup, _upstream, state} = fixture()
    attach_commit_barrier(:reservation)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in({untagged_payload(setup), [opcode: :text]}, state)

    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert ledger_kinds(request) == ["reservation"]

    assert {:ok, %{interrupted_turn_count: 1}} =
             Websocket.interrupt_codex_turn(
               state.codex_session,
               drain_opts(state, request, "owner_crashed")
             )

    assert %{status: "failed", last_error_code: "owner_crashed", usage_status: "usage_unknown"} =
             reloaded = Repo.reload!(request)

    refute Map.has_key?(reloaded.request_metadata, "websocket_pre_attempt_drain")
    assert ledger_kinds(request) == ["release", "reservation"]
    assert release_entry(request).details["release_reason"] == "owner_crashed"
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  # A finalization route with no owner lease of its own carries no out-of-band
  # owner triple, so it releases the reservation and writes no marker: the
  # shape the five `http_sse` production rows have.
  test "interrupt_turn route releases a drain with no owner binding without marking it" do
    {setup, _upstream, state} = fixture()
    attach_commit_barrier(:reservation)

    assert {:ok, state} =
             CodexResponsesSocket.handle_in({untagged_payload(setup), [opcode: :text]}, state)

    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)

    unbound =
      %{state | websocket_owner_lease_token: nil}
      |> drain_opts(request)
      |> RequestOptions.put_transport(websocket_owner_lease_token: nil)

    assert is_nil(unbound.transport.websocket_owner.lease_token)

    assert {:ok, %{interrupted_turn_count: 1}} =
             Websocket.interrupt_codex_turn(state.codex_session, unbound)

    assert %{status: "failed", last_error_code: "owner_drained"} =
             reloaded = Repo.reload!(request)

    refute Map.has_key?(reloaded.request_metadata, "websocket_pre_attempt_drain")
    assert ledger_kinds(request) == ["release", "reservation"]
    assert release_entry(request).details["release_reason"] == "owner_drained"
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  test "owner terminate closes a pre-attempt reservation with marker and release" do
    {setup, upstream, state} = fixture()
    owner = state.websocket_owner_pid
    attach_commit_barrier(:reservation)
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload(setup), [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert ledger_kinds(request) == ["reservation"]

    :ok = GenServer.stop(owner, :shutdown, @budget)
    refute Process.alive?(owner)

    assert_terminal(request, :reservation)
    assert FakeUpstream.count(upstream) == 0
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  # The owner response options the socket itself builds for a drained response
  # task, plus the drain reason it stamps on them. Only the turn selector is
  # supplied here: the socket's own fallback passes its connection-level
  # request id, which never equals a native websocket turn's claim-key
  # correlation id, so that caller cannot select the turn it means to close.
  # The branch under test is reached with the correlation id a correct caller
  # would pass; everything the marker's provenance check reads -- the owner
  # instance id, lease token, and downstream epoch -- still comes from the
  # live socket state, not from the rows being asserted.
  defp drain_opts(state, request, reason \\ "owner_drained") do
    state
    |> DownstreamSession.response_options()
    |> RequestOptions.put_runtime_context(interrupt_reason: reason)
    |> RequestOptions.put_request_metadata(request_id: request.correlation_id)
  end

  # Moves only the two clock columns that decide whether an owner lease has
  # expired, which is what waiting out the lease would do. Nothing an assertion
  # reads is touched.
  defp expire_owner_lease!(session_id) do
    past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(s in CodexSession, where: s.id == ^session_id),
        set: [owner_lease_expires_at: past]
      )

    {1, _} =
      Repo.update_all(
        from(l in BridgeOwnerLease,
          where:
            l.codex_session_id == ^session_id and l.status == ^BridgeOwnerLease.active_status()
        ),
        set: [expires_at: past]
      )

    :ok
  end

  defp untagged_payload(setup) do
    setup
    |> payload()
    |> CodexPooler.JSON.decode!()
    |> Map.delete("client_metadata")
    |> CodexPooler.JSON.encode!()
  end

  defp ledger_kinds(request) do
    Repo.all(
      from e in LedgerEntry,
        where: e.request_id == ^request.id,
        select: e.entry_kind
    )
    |> Enum.sort()
  end

  defp release_entry(request) do
    Repo.one!(
      from e in LedgerEntry,
        where: e.request_id == ^request.id and e.entry_kind == "release"
    )
  end

  defp assert_drain_phase(phase) do
    {setup, upstream, state} = fixture()
    owner = state.websocket_owner_pid
    attach_commit_barrier(phase)
    payload = payload(setup)

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert request.status == if(phase == :claim, do: "accepted", else: "in_progress")

    if phase != :claim,
      do: assert(%{status: "in_progress"} = Repo.get_by!(CodexTurn, request_id: request.id))

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) ==
             if(phase == :attempt, do: 1, else: 0)

    assert FakeUpstream.count(upstream) == 0

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = WebsocketOwnerSession.drain_owner(owner)
      end)

    refute logs =~ "stale_owner_cleanup"
    assert_receive {:websocket_owner_frame, _, _, {:error, :owner_drained, _}} = message, @budget
    assert {:push, _, state} = CodexResponsesSocket.handle_info(message, state)
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, @budget
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert_terminal(request, phase)
    assert FakeUpstream.count(upstream) == 0
  end

  defp fixture do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)

      if previous == nil,
        do: Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled),
        else: Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
    end)

    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        CodexPooler.PoolerFixtures.delete_committed_pools!([setup.pool.id])
        Repo.delete!(setup.identity)
        Repo.delete!(setup.pricing)
      end)
    end)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{request_id: Ecto.UUID.generate(), accepted_turn_state: Ecto.UUID.generate()}
      })

    owner = state.websocket_owner_pid
    on_exit(fn -> if Process.alive?(owner), do: WebsocketOwnerSession.drain_owner(owner) end)
    {setup, upstream, state}
  end

  defp attach_commit_barrier(phase) do
    parent = self()
    barrier = make_ref()

    :ok =
      :telemetry.attach(
        barrier,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata.query

          table = %{claim: "requests", reservation: "codex_turns", attempt: "attempts"}[phase]

          if String.contains?(query, "INSERT INTO") and String.contains?(query, table) do
            Process.put(barrier, true)
          end

          if String.downcase(query) == "commit" and Process.delete(barrier) do
            send(parent, {:reservation_committed, self()})

            receive do
              {:release_reservation, ^barrier} -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(barrier) end)
  end

  defp payload(setup) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [],
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "session_id" => Ecto.UUID.generate(),
            "thread_id" => Ecto.UUID.generate(),
            "turn_id" => Ecto.UUID.generate(),
            "request_kind" => "turn"
          })
      },
      "stream" => true,
      "generate" => true
    })
  end

  defp assert_terminal(request, phase) do
    assert %{status: "failed", last_error_code: "owner_drained", response_status_code: 499} =
             Repo.reload!(request)

    if phase != :claim,
      do:
        assert(
          %{status: "interrupted", error_code: "owner_drained"} =
            Repo.get_by!(CodexTurn, request_id: request.id)
        )

    kinds =
      Repo.all(
        from e in LedgerEntry,
          where: e.request_id == ^request.id,
          select: e.entry_kind
      )

    expected =
      %{
        claim: [],
        reservation: ["release", "reservation"],
        attempt: ["release", "reservation", "settlement"]
      }[phase]

    assert Enum.sort(kinds) == expected

    assert Map.get(Repo.reload!(request).request_metadata, "websocket_pre_attempt_drain") ==
             if(phase == :attempt, do: nil, else: true)

    if phase == :reservation, do: assert_resendable_release(request)
  end

  # The exact release shape `ClientRetry.released_without_settlement?` requires
  # before it will admit a resend against this predecessor.
  defp assert_resendable_release(request) do
    entries =
      Repo.all(
        from e in LedgerEntry,
          where: e.request_id == ^request.id,
          order_by: [asc: e.entry_kind]
      )

    assert [release, reservation] = entries
    assert release.entry_kind == "release"
    assert reservation.entry_kind == "reservation"
    assert is_nil(release.attempt_id)
    assert is_nil(reservation.attempt_id)
    assert release.usage_status == "usage_unknown"
    assert Decimal.equal?(release.settled_cost_micros, 0)
    assert release.details["release_reason"] == "owner_drained"
    assert release.details["reservation_source_event_id"] == reservation.source_event_id

    assert release.details[PreAttemptRelease.detail_key()] ==
             PreAttemptRelease.turn_interrupted()
  end
end
