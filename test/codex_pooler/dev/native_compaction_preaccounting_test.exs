defmodule CodexPooler.Dev.NativeCompactionPreaccountingTest do
  use CodexPoolerWeb.ConnCase, async: false
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport
  alias CodexPooler.{Access, FakeUpstream, Repo, TestAppEnv}
  alias CodexPooler.Dev.NativeCompactionPreaccounting, as: Control
  alias CodexPooler.Dev.NativeCompactionPreaccounting.Plug, as: ControlPlug
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPoolerWeb.CodexResponsesSocket

  @detection_timeout_ms 15_000

  test "rejects unauthenticated or non-loopback control before parsing" do
    denied = Plug.Test.conn(:post, "/arm", "invalid") |> ControlPlug.call([])
    assert denied.status == 403
    remote = %{Plug.Test.conn(:post, "/arm", "invalid") | remote_ip: {203, 0, 113, 1}}
    assert ControlPlug.call(remote, []).status == 403
  end

  for fate <- [:release, :controller_death, :watchdog, :claim_only] do
    test "held real compact reservation is released after #{fate}" do
      held_reservation(unquote(fate))
    end
  end

  defp held_reservation(fate) do
    TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_control_anchor",
              "status" => "completed",
              "output" => []
            }
          })
        ])
      )

    setup = gateway_setup(upstream, compact?: true)

    setup.pool
    |> Ecto.Changeset.change(slug: "codex-compact-control-#{System.unique_integer([:positive])}")
    |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, socket} = owner_socket(auth, "control-socket", "control-session")

    on_exit(fn ->
      Control.disarm(setup.pool.id)
      stop_websocket_owner_session(socket.codex_session.id)
    end)

    metadata = %{
      "turn_id" => "control-turn",
      "window_id" => "control-window",
      "context_window_id" => Ecto.UUID.generate(),
      "window_number" => 1,
      "request_kind" => "turn"
    }

    ordinary =
      websocket_payload(setup, "synthetic", %{
        "client_metadata" => %{"x-codex-turn-metadata" => metadata}
      })

    assert {:ok, socket} = CodexResponsesSocket.handle_in({ordinary, [opcode: :text]}, socket)
    assert {:push, {:text, _}, socket} = receive_owner_socket_push(socket)
    assert {:ok, socket} = receive_socket_turn_done(socket)
    assert {:ok, owner} = WebsocketOwnerSession.lookup(socket.codex_session.id)
    assert {:ok, %{captured: false}} = Control.arm(setup.pool.id)
    foreign_pool = Ecto.UUID.generate()
    assert {:error, :forbidden} = Control.status(foreign_pool)
    assert {:error, :forbidden} = Control.release(foreign_pool)
    assert {:error, :forbidden} = Control.disarm(foreign_pool)

    task =
      Task.async(fn ->
        owner_state = :sys.get_state(owner)
        # This is the actual owner admission boundary with its existing issued binding.
        admission = owner_state.native_compaction_admission

        attrs =
          Map.from_keys(
            [
              :capability,
              :disposition,
              :success?,
              :compaction_item_digest,
              :confirmation,
              :first_compact_collection,
              :expires_at_ms
            ],
            nil
          )

        attrs =
          Map.merge(attrs, %{
            version: 1,
            action: :reserve,
            downstream: Map.take(owner_state.downstream, [:pid, :epoch, :correlation_id]),
            binding: admission.binding,
            phase: :compact,
            control_ref: make_ref(),
            now_ms: System.system_time(:millisecond)
          })

        {:ok, control} =
          WebsocketOwnerAdmissionControlV1.new(attrs)

        WebsocketOwnerSession.admission_control(owner, control)
      end)

    assert_capture(setup.pool.id, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    finish_control(fate, setup, task)
    assert {:ok, %{armed: false}} = Control.disarm(setup.pool.id)
    assert :ok = CodexResponsesSocket.terminate(:closed, socket)
  end

  defp finish_control(:release, %{pool: %{id: pool_id}}, task) do
    # Capture was observed before release; the held owner call must now finish.
    assert {:ok, %{released: true, compact_request_count: 0}} = Control.release(pool_id)
    assert {:ok, _} = Task.await(task, @detection_timeout_ms)
  end

  defp finish_control(:controller_death, _setup, task) do
    pid = Process.whereis(Control)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, _} = Task.await(task, @detection_timeout_ms)
    assert_no_control_handler(System.monotonic_time(:millisecond) + @detection_timeout_ms)
  end

  defp finish_control(:watchdog, %{pool: %{id: pool_id}}, task) do
    send(Process.whereis(Control), :watchdog)
    assert {:ok, _} = Task.await(task, @detection_timeout_ms)
    assert {:ok, %{timed_out: true}} = Control.status(pool_id)
  end

  defp finish_control(:claim_only, setup, task) do
    assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, _claim} =
             CodexPooler.Accounting.claim_websocket_turn(auth, setup.model, %{
               endpoint: "/backend-api/codex/responses/compact",
               correlation_id: "claim-only-#{System.unique_integer([:positive])}"
             })

    assert {:ok, %{compact_request_count: 1}} = Control.release(setup.pool.id)
    assert {:ok, _} = Task.await(task, @detection_timeout_ms)
  end

  defp assert_no_control_handler(deadline) do
    remaining =
      :telemetry.list_handlers([
        :codex_pooler,
        :gateway,
        :native_compaction,
        :authorization_transition
      ])
      |> Enum.any?(fn %{id: id} -> match?({Control, _}, id) end)

    if remaining do
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        5 -> assert_no_control_handler(deadline)
      end
    end
  end

  defp assert_capture(pool_id, deadline) do
    assert {:ok, status} = Control.status(pool_id)
    if status.captured, do: :ok, else: wait_capture(pool_id, deadline)
  end

  defp wait_capture(pool_id, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    receive do
    after
      5 -> assert_capture(pool_id, deadline)
    end
  end
end
