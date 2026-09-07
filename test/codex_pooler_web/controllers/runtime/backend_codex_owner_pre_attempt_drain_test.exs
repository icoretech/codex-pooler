defmodule CodexPoolerWeb.Runtime.BackendCodexOwnerPreAttemptDrainTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket.DirectCleanup
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

    for invalid <- [
          Map.delete(receipt, :owner_binding),
          %{receipt | owner_binding: nil},
          %{receipt | owner_binding: %{}},
          put_in(receipt.owner_binding.owner_lease_token, Ecto.UUID.generate()),
          put_in(
            receipt.owner_binding.downstream_epoch,
            receipt.owner_binding.downstream_epoch + 1
          )
        ] do
      assert :ok = DirectCleanup.interrupt(invalid, "owner_drained")
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
  end
end
