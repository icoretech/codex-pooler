defmodule CodexPooler.Dev.NativePreAttemptDrainBoundaryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  alias CodexPooler.{Access, FakeUpstream, Repo}
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Dev.NativePreAttemptDrain
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag capture_log: true
  test "captures a real committed reservation once and releases its actual response task" do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      NativePreAttemptDrain.disarm()
      Sandbox.mode(Repo, :manual)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
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

    :ok = NativePreAttemptDrain.arm(setup.pool.id)

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [],
        "stream" => true,
        "generate" => true
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    deadline = System.monotonic_time(:millisecond) + 15_000
    assert await_capture(deadline)
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert request.status == "in_progress"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
    assert FakeUpstream.count(upstream) == 0
    assert :ok = NativePreAttemptDrain.drain()
    assert_receive {:websocket_owner_frame, _, _, {:error, :owner_drained, _}} = message, 15_000
    assert {:push, _, state} = CodexResponsesSocket.handle_info(message, state)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert Repo.reload!(request).last_error_code == "owner_drained"
    assert :ok = NativePreAttemptDrain.disarm()
    refute NativePreAttemptDrain.status().armed
  end

  defp await_capture(deadline) do
    cond do
      NativePreAttemptDrain.status().captured ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          5 -> await_capture(deadline)
        end
    end
  end
end
