defmodule CodexPooler.Gateway.Websocket.DirectCleanupPostgresTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.AccountingTestSupport
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  for kill_phase <- [:before_commit, :after_commit] do
    test "#{kill_phase} coordinator death resolves exact bound transaction without guessed cleanup" do
      assert_killed_transaction(unquote(kill_phase))
    end
  end

  defp assert_killed_transaction(kill_phase) do
    {setup, session} = fixture()
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({ActivityRegistry, name: name})
    parent = self()
    ref = make_ref()

    coordinator =
      spawn(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          context = %DirectCleanup{
            registry: name,
            task: self(),
            ref: ref,
            parent: parent,
            session_id: session.id
          }

          {:ok, token} =
            ActivityRegistry.register(:direct, self(),
              name: name,
              direct_cleanup_ref: ref,
              direct_cleanup_parent: parent
            )

          :ok = ActivityRegistry.admit(token, name: name)
          :ok = ActivityRegistry.begin_direct_cleanup(context)
          send(parent, {:context, context})

          result =
            Accounting.claim_websocket_turn(setup.auth, setup.model, %{
              correlation_id: Ecto.UUID.generate(),
              endpoint: "/backend-api/codex/responses",
              direct_cleanup_bind: fn request ->
                :ok = DirectCleanup.bind(context, request)
                send(parent, {:bound, request.id})

                receive do
                  :commit -> :ok
                end
              end
            })

          send(parent, {:committed, result})

          receive do
            :finish -> :ok
          end
        end)
      end)

    monitor = Process.monitor(coordinator)
    assert_receive {:context, context}, 15_000
    assert_receive {:bound, request_id}, 15_000

    if kill_phase == :after_commit do
      send(coordinator, :commit)
      assert_receive {:committed, {:ok, _}}, 15_000
    end

    cleanup =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> DirectCleanup.cancel(context, "client_disconnected") end)
      end)

    assert Task.yield(cleanup, 0) == nil

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(coordinator, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 15_000
        assert :ok = Task.await(cleanup, 15_000)
      end)

    if kill_phase == :before_commit, do: assert(log =~ "DBConnection.ConnectionError")

    Sandbox.unboxed_run(Repo, fn ->
      case kill_phase do
        :before_commit ->
          assert Repo.get(Request, request_id) == nil

        :after_commit ->
          assert %{status: "failed", last_error_code: "client_disconnected"} =
                   Repo.get!(Request, request_id)

          assert Repo.get(RequestLogFact, request_id)
      end

      assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^request_id), :count) ==
               0
    end)

    _consumed = ActivityRegistry.await_direct_cleanup(context)
    assert :sys.get_state(name).finished_direct == %{}
  end

  test "failed predecessor receipt cannot interrupt a replacement turn" do
    {setup, session} = fixture()

    Sandbox.unboxed_run(Repo, fn ->
      {:ok, old} =
        Accounting.reserve(setup.auth, setup.model, %{}, %{
          transport: "websocket",
          requested_model: setup.model.exposed_model_id,
          correlation_id: Ecto.UUID.generate()
        })

      {:ok, old_turn} = Websocket.start_codex_turn(session, old.request)
      old.request |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
      old_turn |> Ecto.Changeset.change(status: "failed") |> Repo.update!()

      {:ok, current} =
        Accounting.reserve(setup.auth, setup.model, %{}, %{
          transport: "websocket",
          requested_model: setup.model.exposed_model_id,
          correlation_id: Ecto.UUID.generate()
        })

      {:ok, current_turn} = Websocket.start_codex_turn(session, current.request)
      current = %{current | request: Repo.reload!(current.request)}

      receipt = %{
        session_id: session.id,
        request_id: old.request.id,
        correlation_id: old.request.correlation_id,
        api_key_id: setup.api_key.id
      }

      assert :ok = DirectCleanup.interrupt(receipt, "client_disconnected")
      assert Repo.reload!(current.request) == current.request
      assert Repo.reload!(current_turn) == current_turn
      assert Repo.reload!(session).status == "active"

      assert :ok =
               DirectCleanup.interrupt(
                 %{receipt | api_key_id: Ecto.UUID.generate()},
                 "client_disconnected"
               )

      assert Repo.reload!(current.request) == current.request
    end)
  end

  defp fixture do
    Sandbox.unboxed_run(Repo, fn ->
      setup = AccountingTestSupport.accounting_setup()

      {:ok, session} =
        Websocket.start_codex_session(setup.auth, %{accepted_turn_state: Ecto.UUID.generate()})

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete!(setup.pool)
          Repo.delete!(setup.identity)
          Repo.delete!(setup.pricing)
        end)
      end)

      {setup, session}
    end)
  end
end
