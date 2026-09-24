defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ReservedPreAttemptInterruptTest do
  # The socket's direct interrupt closes a reserved websocket request by the
  # shape it finds: a claim-only row, a reserved row with its turn and no
  # attempt, or an attempted turn. A reserved row with neither a turn nor an
  # attempt has no branch of its own and would keep its reservation, and with
  # it a capped key's slot, until the six-hour stale sweep (findings#206 row
  # 206-468). That shape is unreachable because the reservation, the turn
  # insert and the receipt bind share one transaction under the session lock;
  # these two tests pin both halves:
  #
  # - a client that leaves after the reservation commits and before the attempt
  #   exists finds a turn beside the reservation, and the interrupt ends the
  #   request, releases its reservation and frees the capped key's slot;
  # - a fault at the turn insert rolls the reservation back with it, so no
  #   reserved row without a turn is ever committed.
  #
  # One node, native websocket, Full, owner forwarding on and off,
  # FakeUpstream, synthetic text; nothing reaches the provider.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.LedgerReads
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @moduletag capture_log: true

  # Failure-detection budget: every wait returns as soon as its message
  # arrives, so only a missing one spends it.
  @detection_timeout_ms 15_000

  for forwarding <- [:forwarded, :direct] do
    @tag forwarding: forwarding
    test "#{forwarding}: a client that leaves after the reservation and before the attempt ends the request and frees the capped key's slot",
         %{forwarding: forwarding} do
      fixture = capped_fixture!(forwarding)
      parent = self()

      state =
        fixture.state
        |> Map.put(:response_task_start_options,
          before_direct_cleanup_ready: fn ->
            send(parent, {:reservation_committed, self()})

            receive do
              :resume -> :ok
            end
          end
        )

      assert {:ok, state} = CodexResponsesSocket.handle_in({fixture.frame, [opcode: :text]}, state)
      assert_receive {:reservation_committed, task}, @detection_timeout_ms

      assert [request] = pool_requests(fixture.setup.pool.id)

      assert %{status: "in_progress", turn: "in_progress", attempts: 0, reservation_outstanding: true} =
               request_shape(request)

      # The cap is live: the held request fills the key's only slot.
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve_other(fixture)

      monitor = Process.monitor(task)
      Process.exit(task, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, @detection_timeout_ms
      assert :ok = WebsocketCleanupFence.terminate_and_await!(:closed, state)

      assert %{
               status: "failed",
               code: "client_disconnected",
               response_status_code: 499,
               turn: "interrupted",
               attempts: 0,
               reservation_outstanding: false,
               release_phase: "turn_interrupted"
             } = request_shape(Repo.reload!(request))

      assert LedgerReads.outstanding_reservation_count(fixture.setup.api_key.id) == 0
      assert {:ok, %{request: other}} = reserve_other(fixture)
      release!(other)
      assert FakeUpstream.count(fixture.upstream) == 0
    end
  end

  for forwarding <- [:forwarded, :direct] do
    @tag forwarding: forwarding
    test "#{forwarding}: a fault at the turn insert rolls the reservation back with it", %{forwarding: forwarding} do
      fixture = capped_fixture!(forwarding)
      parent = self()
      install_turn_insert_fault!()

      # The readiness hook also runs when the admission returns without a
      # reservation, after the refusal has settled the claim.
      state =
        Map.put(fixture.state, :response_task_start_options, before_direct_cleanup_ready: fn -> send(parent, {:admission_settled, self()}) end)

      assert {:ok, state} = CodexResponsesSocket.handle_in({fixture.frame, [opcode: :text]}, state)
      assert_receive {:admission_settled, task}, @detection_timeout_ms
      assert_receive {:codex_response_done, ^task, result}, @detection_timeout_ms
      remove_turn_insert_fault!()

      assert {:socket_response_result, _source, {:response_task_result, {:error, %{status: 503, code: "service_unavailable"}}, false}} = result

      shapes = fixture.setup.pool.id |> pool_requests() |> Enum.map(&request_shape/1)
      assert Enum.all?(shapes, &(&1.status not in ["accepted", "in_progress"])), inspect(shapes)
      assert Enum.all?(shapes, &(&1.reservation_outstanding == false)), inspect(shapes)
      assert reservation_entries(fixture.setup.api_key.id) == 0
      assert Repo.aggregate(from(t in CodexTurn, join: r in Request, on: r.id == t.request_id, where: r.pool_id == ^fixture.setup.pool.id), :count) == 0

      assert LedgerReads.outstanding_reservation_count(fixture.setup.api_key.id) == 0
      assert {:ok, %{request: other}} = reserve_other(fixture)
      release!(other)

      assert :ok = WebsocketCleanupFence.terminate_and_await!(:closed, state)
      assert FakeUpstream.count(fixture.upstream) == 0
    end
  end

  defp capped_fixture!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)

    upstream = start_upstream(FakeUpstream.websocket_text_frames([completed_frame("resp_reserved_pre_attempt_unexpected")]))
    setup = gateway_setup(upstream)
    Repo.update_all(from(key in CodexPooler.Access.APIKey, where: key.id == ^setup.api_key.id), set: [max_active_requests: 1])
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    thread_id = Ecto.UUID.generate()

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{request_id: "reserved-pre-attempt-#{forwarding}", accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}
      })

    if forwarding == :forwarded, do: assert(is_pid(Map.get(state, :websocket_owner_pid)))

    %{
      upstream: upstream,
      setup: setup,
      auth: auth,
      state: state,
      frame: CodexPooler.JSON.encode!(native_turn_payload(thread_id, setup.model.exposed_model_id, "reserved-pre-attempt-turn"))
    }
  end

  defp reserve_other(fixture) do
    Accounting.reserve(fixture.auth, fixture.setup.model, %{"model" => fixture.setup.model.exposed_model_id, "max_output_tokens" => 10}, %{correlation_id: "reserved-pre-attempt-other-#{System.unique_integer([:positive])}"})
  end

  defp release!(request) do
    {:ok, _released} =
      Accounting.finalize_reserved_request_failure(request, %{request_status: "failed", response_status_code: 499, last_error_code: "client_disconnected", usage_status: "not_applicable"})
  end

  # `admin_shutdown` is the retryable database failure the reservation answers
  # with a 503 after rolling back.
  defp install_turn_insert_fault! do
    Repo.query!("CREATE FUNCTION pg_temp.p108_turn_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'terminating connection due to administrator command' USING ERRCODE = 'admin_shutdown'; END $$")
    Repo.query!("CREATE TRIGGER p108_turn_fault BEFORE INSERT ON codex_turns FOR EACH ROW EXECUTE FUNCTION pg_temp.p108_turn_fault()")
  end

  defp remove_turn_insert_fault!, do: Repo.query!("DROP TRIGGER p108_turn_fault ON codex_turns")

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id and r.transport == "websocket"))

  defp request_shape(%Request{} = request) do
    release =
      Repo.one(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "release", order_by: [desc: e.occurred_at], limit: 1, select: e.details))

    %{
      status: request.status,
      code: request.last_error_code,
      response_status_code: request.response_status_code,
      turn: Repo.one(from(t in CodexTurn, where: t.request_id == ^request.id, select: t.status)),
      attempts: Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count),
      reservation_outstanding: Accounting.reservation_outstanding?(request),
      release_phase: release && release["pre_attempt_phase"]
    }
  end

  defp reservation_entries(api_key_id),
    do: Repo.aggregate(from(e in LedgerEntry, where: e.api_key_id == ^api_key_id and e.entry_kind == "reservation"), :count)

  defp native_turn_payload(thread_id, model, turn_id) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => turn_id,
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => turn_id, "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic reserved pre-attempt turn"}]}]
    }
  end

  defp completed_frame(response_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
    })
  end
end
