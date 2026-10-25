defmodule CodexPoolerWeb.Runtime.NativeHttpAdmissionCommitRecoveryTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, native_text_input: 1, register_unboxed_pool_cleanup!: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, PreAttemptRelease, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @path "/backend-api/codex/responses"
  @moduletag capture_log: true

  defmodule CommitFailureEndpoint do
    @behaviour Plug
    def init(config), do: config

    def call(conn, %{gate: gate, owner: owner, reference: reference}) do
      if Agent.get_and_update(gate, &{&1, false}) do
        Process.put({Service, :runtime_authorization_barrier}, {owner, reference, {:reservation_commit, :after}})
      end

      CodexPoolerWeb.Endpoint.call(conn, CodexPoolerWeb.Endpoint.init([]))
    end
  end

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "a real committed native tool reservation whose acknowledgement fails recovers before the identical HTTP retry" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created", %{"type" => "response.created", "response" => %{"id" => "resp_admission_retry", "status" => "in_progress"}}},
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_admission_retry", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}}}}
        ])
      )

    fixture = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(fixture)
    gate = start_supervised!({Agent, fn -> true end})
    reference = make_ref()
    server = start_supervised!({Bandit, plug: {CommitFailureEndpoint, %{gate: gate, owner: self(), reference: reference}}, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    thread = Ecto.UUID.generate()
    metadata = CodexPooler.JSON.encode!(%{"thread_id" => thread, "session_id" => thread, "turn_id" => "synthetic_admission_turn", "request_kind" => "turn", "agent_name" => "/root", "window_id" => "#{thread}:0", "window_number" => 0})
    payload = %{"model" => fixture.model.exposed_model_id, "instructions" => "synthetic instructions", "tools" => [], "input" => native_text_input("synthetic question") ++ [%{"type" => "function_call", "call_id" => "call_admission", "name" => "synthetic_tool", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => "call_admission", "output" => "synthetic result"}, %{"type" => "reasoning", "id" => "rs_synthetic_retained", "summary" => [], "encrypted_content" => "synthetic"}, %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic update"}]}], "stream" => true, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}
    headers = auth(build_conn(), fixture).req_headers ++ [{"session-id", thread}, {"thread-id", thread}, {"x-codex-window-id", "#{thread}:0"}, {"x-codex-turn-metadata", metadata}]
    request = fn -> Req.post!("http://127.0.0.1:#{port}#{@path}", headers: headers, json: payload, retry: false, receive_timeout: 15_000) end
    client = Task.async(request)
    monitor = Process.monitor(client.pid)
    assert_receive {:runtime_authorization_barrier, ^reference, :reservation_commit, :after, executor}, 15_000
    # The endpoint's transaction really committed: this independent connection
    # observes all three rows before the simulated acknowledgement failure.
    [original] = pool_requests(fixture)
    assert original.request_metadata["native_http_claim_arm"] == "tool_continuation"
    assert original.status == "in_progress"
    assert %CodexTurn{status: "in_progress", first_visible_output_at: nil} = Repo.get_by!(CodexTurn, request_id: original.id)
    assert kinds(original) == ["reservation"]
    refute Repo.exists?(from(a in Attempt, where: a.request_id == ^original.id))
    assert FakeUpstream.count(upstream) == 0

    {refusal, logs} =
      ExUnit.CaptureLog.with_log(fn ->
        send(executor, {:runtime_authorization_failure, reference, DBConnection.ConnectionError.exception("synthetic committed acknowledgement loss")})
        Task.await(client, 15_000)
      end)

    assert %{status: 503} = refusal
    assert logs =~ "runtime request refused before dispatch stage=reservation reason_class=DBConnection.ConnectionError"
    refute logs =~ "synthetic committed acknowledgement loss"
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 15_000
    CodexPooler.ExecutionProofSupport.publish_committed_terminal!(%{owner_execution_id: original.admission_execution_id, owner_instance_id: original.admission_instance_id, owner_instance_boot_id: original.admission_instance_boot_id, owner_process_id: original.admission_process_id})
    handler = {__MODULE__, reference}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, PreAttemptRelease.telemetry_event(), &__MODULE__.observe_release/4, self())
    response = request.()
    assert response.status == 200
    assert_receive {:native_admission_release, false}, 1_000
    assert response.body =~ "response.completed"
    [original, successor] = pool_requests(fixture)
    assert {original.status, original.last_error_code, original.usage_status} == {"failed", "admission_execution_recovered", "not_applicable"}
    assert %CodexTurn{status: "interrupted", error_code: "admission_execution_recovered", final_attempt_id: nil} = Repo.get_by!(CodexTurn, request_id: original.id)
    assert kinds(original) == ["release", "reservation"]
    assert successor.status == "succeeded"
    assert String.starts_with?(successor.correlation_id, "codex-request-retry:")
    assert Repo.exists?(from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^original.id and l.successor_request_id == ^successor.id))
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^successor.id), :count) == 1
    assert Enum.count(kinds(successor), &(&1 == "settlement")) == 1
  end

  @doc false
  def observe_release(_event, _measurements, %{release_reason: "admission_execution_recovered"}, owner), do: send(owner, {:native_admission_release, Repo.in_transaction?()})
  def observe_release(_event, _measurements, _metadata, _owner), do: :ok

  defp pool_requests(fixture), do: Repo.all(from(r in Request, where: r.pool_id == ^fixture.pool.id, order_by: [asc: r.admitted_at]))
  defp kinds(request), do: Repo.all(from(l in LedgerEntry, where: l.request_id == ^request.id, order_by: l.entry_kind, select: l.entry_kind))
end
