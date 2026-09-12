defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketTurnAuthorityTest do
  # A zero `interrupted_turn_count` used to mean two different things, and the
  # caller could not tell which: the session had nothing in flight, or the
  # identifier the caller holds could not name the turn that does
  # (icoretech/codex-pooler-findings#179). Only the first is a completed
  # cleanup. Nothing durable recorded the second, which is why a native
  # websocket cleanup that selected nothing stayed invisible long enough to
  # produce two wrong explanations for the finalization branch in #178.
  #
  # Every row here is written by a real socket driven through `init/1`,
  # `handle_in/2` and `terminate/2`. Only the turn selector is ever supplied by
  # the test, and only in the case whose claim is that the exact correlation id
  # still works.
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @budget 15_000
  @moduletag capture_log: true

  # The shape the ticket describes: a socket holding the session, an in-flight
  # turn it did not start, and a connection-level request id that is not that
  # turn's claim-key correlation id. The selector matches nothing, and the
  # refusal must be visible as a refusal.
  test "a socket that cannot name the session's in-flight turn reports no authority" do
    {setup, upstream, parked} = parked_turn_fixture()
    request = parked.request
    rejoined = rejoin_session(setup, parked.state)

    refute rejoined.opts.request_id == request.correlation_id
    assert Map.get(rejoined, :direct_cleanup_contexts) == %{}

    logs = with_interruption_info(fn -> CodexResponsesSocket.terminate(:closed, rejoined) end)

    assert logs =~ "websocket interrupt selector resolved no turn"
    assert logs =~ "codex_session_id=#{parked.state.codex_session.id}"
    assert logs =~ "turn_selector=request_id"
    assert logs =~ "active_turn_count=1"
    assert logs =~ "turn_authority=unresolved"

    # The refusal is also a value, not only a log line.
    assert {:ok, %{interrupted_turn_count: 0, turn_authority: :unresolved}} =
             Gateway.interrupt_codex_session(parked.state.codex_session, rejoined.opts)

    # Refused, never seized: an unnamed in-progress turn may belong to a
    # connection that is still serving it, so nothing about it moves.
    assert %{status: "in_progress"} = Repo.reload!(request)
    assert %{status: "in_progress"} = Repo.get_by!(CodexTurn, request_id: request.id)
    assert ledger_kinds(request) == ["reservation"]
    assert attempt_count(request) == 0
    assert FakeUpstream.count(upstream) == 0
  end

  # The other half of the same claim: the exact identifier the turn was durably
  # correlated with still selects it, closes it once, and says it had authority.
  test "the exact request correlation id selects the turn and finalizes it once" do
    {setup, upstream, parked} = parked_turn_fixture()
    request = parked.request
    rejoined = rejoin_session(setup, parked.state)
    named = Map.put(rejoined.opts, :request_id, request.correlation_id)

    logs =
      with_interruption_info(fn ->
        assert {:ok, %{interrupted_turn_count: 1, turn_authority: :selected}} =
                 Gateway.interrupt_codex_session(parked.state.codex_session, named)
      end)

    refute logs =~ "websocket interrupt selector resolved no turn"

    assert %{status: "failed", last_error_code: "client_disconnected", response_status_code: 499} =
             reloaded = Repo.reload!(request)

    assert %{status: "interrupted", error_code: "client_disconnected"} =
             Repo.get_by!(CodexTurn, request_id: request.id)

    # One finalization: exactly one release, no settlement, nothing sent
    # upstream. The turn never reached an attempt, so this is the release-only
    # branch, and it must still write no resend marker
    # (icoretech/codex-pooler-findings#178).
    assert ledger_kinds(request) == ["release", "reservation"]
    refute Map.has_key?(reloaded.request_metadata, "websocket_pre_attempt_drain")
    assert attempt_count(request) == 0
    assert FakeUpstream.count(upstream) == 0

    # Repeating it still names the same turn, finds it already terminal, and
    # releases nothing a second time. The zero is reported with authority,
    # which is the whole distinction: it is not the refused zero above.
    assert {:ok, %{interrupted_turn_count: 0, turn_authority: :selected}} =
             Gateway.interrupt_codex_session(parked.state.codex_session, named)

    assert ledger_kinds(request) == ["release", "reservation"]
    assert FakeUpstream.count(upstream) == 0
  end

  # The control: nothing was in flight. This zero is a completed cleanup, and
  # it must not be reported with the same authority as the refused one above.
  test "an idle socket reports a genuine zero rather than an unresolved selector" do
    {setup, upstream, state} = fixture()
    session = state.codex_session

    logs = with_interruption_info(fn -> CodexResponsesSocket.terminate(:closed, state) end)

    refute logs =~ "websocket interrupt selector resolved no turn"

    assert {:ok, %{interrupted_turn_count: 0, turn_authority: authority}} =
             Gateway.interrupt_codex_session(session, state.opts)

    assert authority == :session_idle
    refute authority == :unresolved
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    assert FakeUpstream.count(upstream) == 0
  end

  # The receipt path, which is the one that carries the exact request id the
  # response task bound. It must keep closing the socket's own turn exactly
  # once, with no selector refusal anywhere in the teardown.
  test "the direct cleanup receipt closes the socket's own turn exactly once" do
    {_setup, upstream, parked} = parked_turn_fixture()
    request = parked.request

    monitor = Process.monitor(parked.task)
    Process.exit(parked.task, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, _}, @budget

    logs = with_interruption_info(fn -> CodexResponsesSocket.terminate(:closed, parked.state) end)

    refute logs =~ "websocket interrupt selector resolved no turn"

    assert %{status: "failed", last_error_code: "client_disconnected", response_status_code: 499} =
             reloaded = Repo.reload!(request)

    assert %{status: "interrupted", error_code: "client_disconnected"} =
             Repo.get_by!(CodexTurn, request_id: request.id)

    assert ledger_kinds(request) == ["release", "reservation"]
    refute Map.has_key?(reloaded.request_metadata, "websocket_pre_attempt_drain")
    assert attempt_count(request) == 0
    assert FakeUpstream.count(upstream) == 0
  end

  # A socket parked exactly inside the pre-attempt window: claimed, reserved,
  # no attempt row, nothing sent upstream, and a durable correlation id that is
  # the native turn's claim key rather than any connection-level id.
  defp parked_turn_fixture do
    {setup, upstream, state} = fixture()
    attach_commit_barrier(:reservation)

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload(setup), [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)

    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert request.status == "in_progress"
    assert %{status: "in_progress"} = Repo.get_by!(CodexTurn, request_id: request.id)
    assert attempt_count(request) == 0
    assert ledger_kinds(request) == ["reservation"]

    # The namespace mismatch the ticket is about, asserted rather than assumed.
    refute request.correlation_id == state.opts.request_id

    {setup, upstream, %{state: state, request: request, task: task}}
  end

  # A second connection resuming the same codex session through the real socket
  # entry point. It holds the session and no direct-cleanup context, which is
  # the only shape in which the connection-level fallback runs at all.
  defp rejoin_session(setup, state) do
    {:ok, rejoined} =
      CodexResponsesSocket.init(%{
        auth: setup.auth,
        opts: %{
          request_id: Ecto.UUID.generate(),
          accepted_turn_state: state.opts.accepted_turn_state
        }
      })

    assert rejoined.codex_session.id == state.codex_session.id
    rejoined
  end

  # The suite runs at :warning; the selector-refusal line is an :info the
  # production default level does emit, so raise it for this module only.
  defp with_interruption_info(fun) do
    :ok = Logger.put_module_level(Interruption, :info)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.delete_module_level(Interruption)
    end
  end

  defp fixture do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
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
        Repo.delete!(setup.pool)
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

    {Map.put(setup, :auth, auth), upstream, state}
  end

  # Parks the response task on the commit that closes the reservation, the last
  # durable write before an attempt row exists.
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

  defp ledger_kinds(request) do
    Repo.all(from e in LedgerEntry, where: e.request_id == ^request.id, select: e.entry_kind)
    |> Enum.sort()
  end

  defp attempt_count(request) do
    Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count)
  end
end
