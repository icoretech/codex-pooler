defmodule CodexPoolerWeb.Runtime.BackendCodexHttpPartialToolRetryTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, register_unboxed_pool_cleanup!: 1, native_text_input: 1, start_public_endpoint!: 0, start_upstream: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag capture_log: true
  @path "/backend-api/codex/responses"
  @detection_timeout_ms 15_000

  for mode <- ["full", "lite"], arm <- [:opening, :tool_continuation], tool_type <- ["custom_tool_call", "function_call"] do
    @tag mode: mode, arm: arm, tool_type: tool_type
    test "an identical #{mode} native HTTP #{arm} retries a partial #{tool_type} exactly once", %{mode: mode, arm: arm, tool_type: tool_type} do
      {upstream, setup, port, thread_id, payload} = scenario(mode, arm, partial_events(tool_type), [FakeUpstream.sse_stream([completed_event()])])
      assert_cut!(port, setup, payload, thread_id, tool_type)
      [first] = pool_requests(setup)
      contract = partial_retry_contract()
      assert first.transport == contract.predecessor_transport
      assert first.last_error_code == contract.predecessor_error
      assert first.request_metadata["native_http_claim_arm"] == Atom.to_string(arm)
      assert first.request_metadata["native_http_claim_arm"] in contract.claim_arms
      assert tool_type in contract.partial_tools

      {retry_status, retry_body} = post_stream!(port, setup, payload, thread_id)
      assert {retry_status, retry_body =~ "response.completed"} == {200, true}
      assert [_, %Request{status: "succeeded"} = retry] = pool_requests(setup)
      assert [%Attempt{status: "failed"} = first_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^first.id))
      assert first_attempt.response_metadata["native_http_partial_tool"] == %{"version" => 1, "parser_complete" => contract.requires_complete_observation, "poisoned" => false, "partial_tool" => tool_type, "input_done" => false}
      assert retry.request_metadata["client_resend"]["predecessor_request_id"] == first.id
      assert [%RequestClientRetryLink{successor_request_id: successor_id}] = Repo.all(from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^first.id))
      assert successor_id == retry.id
      assert [%Attempt{status: "succeeded"}] = Repo.all(from(a in Attempt, where: a.request_id == ^retry.id))
      assert_settled_once!([first.id, retry.id])

      assert_refused!(port, setup, payload, thread_id)
      assert FakeUpstream.count(upstream) == 1 + contract.retry_limit
      assert length(pool_requests(setup)) == 1 + contract.retry_limit
      assert_settled_once!([first.id, retry.id])
    end
  end

  for control <- [:completed_item, :created_output, :unknown_event, :malformed_event, :truncated_event, :oversized_event, :missing_proof, :poisoned_proof, :incomplete_proof, :changed_body, :anchor, :replay_generation, :expired, :missing_digest, :changed_epoch] do
    @tag control: control
    test "a partial native HTTP tool call keeps the duplicate fence for #{control}", %{control: control} do
      events =
        if control == :created_output do
          [created | remaining] = partial_events("custom_tool_call")
          {name, body} = created
          [{name, put_in(body, ["response", "output"], [%{"type" => "message", "id" => "msg_synthetic_prior"}])} | remaining]
        else
          partial_events("custom_tool_call") ++ control_events(control)
        end

      {upstream, setup, port, thread_id, payload} = scenario("full", :opening, events)
      assert_cut!(port, setup, payload, thread_id, "custom_tool_call", control == :completed_item)
      [first] = pool_requests(setup)
      apply_negative_state!(first, control)

      retry_payload =
        case control do
          :changed_body -> Map.put(payload, "instructions", "different synthetic instructions")
          :anchor -> Map.put(payload, "previous_response_id", "resp_synthetic_anchor")
          _ -> payload
        end

      assert_refused!(port, setup, retry_payload, thread_id)
      assert FakeUpstream.count(upstream) == 1
      assert length(pool_requests(setup)) == 1
      assert [%Attempt{}] = Repo.all(from(a in Attempt, where: a.request_id == ^first.id))
      assert_settled_once!([first.id])
    end
  end

  test "a second partial cut cannot buy another retry in the same lineage" do
    {upstream, setup, port, thread_id, payload} = scenario("full", :opening, partial_events("custom_tool_call"), [FakeUpstream.abrupt_close_mid_stream(partial_events("custom_tool_call"))])
    assert_cut!(port, setup, payload, thread_id, "custom_tool_call")
    {retry_status, retry_body} = post_stream!(port, setup, payload, thread_id)
    assert {retry_status, retry_body =~ "response.custom_tool_call_input.delta"} == {200, true}
    requests = pool_requests(setup)
    assert Enum.map(requests, &{&1.status, &1.last_error_code}) == [{"failed", "upstream_stream_error"}, {"failed", "upstream_stream_error"}]
    assert_refused!(port, setup, payload, thread_id)
    assert FakeUpstream.count(upstream) == 2
    assert length(pool_requests(setup)) == 2
    assert_settled_once!(Enum.map(requests, & &1.id))
  end

  for mode <- ["full", "lite"], tool_type <- ["custom_tool_call", "function_call"] do
    @tag mode: mode, tool_type: tool_type
    test "clean EOF after #{mode} #{tool_type} input.done admits one identical retry", %{mode: mode, tool_type: tool_type} do
      events = partial_events(tool_type) ++ [input_done_event(tool_type)]
      {upstream, setup, port, thread_id, payload} = scenario(mode, :opening, events, [FakeUpstream.sse_stream([completed_event()])], :clean)
      assert_cut!(port, setup, payload, thread_id, tool_type)
      [first] = pool_requests(setup)
      attempt = Repo.get_by!(Attempt, request_id: first.id)
      assert attempt.response_metadata["native_http_partial_tool"] == %{"version" => 1, "parser_complete" => true, "poisoned" => false, "partial_tool" => tool_type, "input_done" => true}
      {status, body} = post_stream!(port, setup, payload, thread_id)
      assert {status, body =~ "response.completed"} == {200, true}
      assert_refused!(port, setup, payload, thread_id)
      assert FakeUpstream.count(upstream) == 2
      assert_settled_once!(Enum.map(pool_requests(setup), & &1.id))
    end
  end

  for mode <- ["full", "lite"] do
    @tag mode: mode
    test "clean EOF after #{mode} completed tool item stays fenced", %{mode: mode} do
      events = partial_events("custom_tool_call") ++ [input_done_event("custom_tool_call")] ++ control_events(:completed_item)
      {upstream, setup, port, thread_id, payload} = scenario(mode, :opening, events, [], :clean)
      {status, body} = post_stream!(port, setup, payload, thread_id)
      assert status == 200
      assert body =~ "response.output_item.done"
      refute body =~ "response.completed"
      assert_refused!(port, setup, payload, thread_id)
      assert FakeUpstream.count(upstream) == 1
      assert [request] = pool_requests(setup)
      assert_settled_once!([request.id])
    end
  end

  @tag timeout: 60_000
  test "concurrent identical HTTP retries on independent PostgreSQL connections admit one successor", context do
    CodexPooler.DataCase.stop_sandbox(context.sandbox_owner, context.sandbox_settings_cache)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok = Sandbox.mode(Repo, :auto)
    %{user: owner} = CodexPooler.AccountsFixtures.committed_bootstrap_owner_fixture!()
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.abrupt_close_mid_stream(partial_events("custom_tool_call")), FakeUpstream.sse_stream([completed_event()])]))
    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    scope = Scope.for_user(owner, ["instance_owner"])
    _revision = set_model_serving_mode!(scope, setup, "full")
    setup = Map.put(setup, :serving_mode, "full")
    port = start_public_endpoint!()
    thread_id = Ecto.UUID.generate()
    payload = native_payload(setup, thread_id, :opening)
    assert_cut!(port, setup, payload, thread_id, "custom_tool_call")
    [first] = pool_requests(setup)
    session_id = Repo.get_by!(CodexTurn, request_id: first.id).codex_session_id
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    barrier = make_ref()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Repo.transaction(fn ->
          Repo.one!(from(s in CodexSession, where: s.id == ^session_id, lock: "FOR UPDATE"))
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:session_locked, barrier, backend})

          receive do
            {:release_session, ^barrier} -> :ok
          after
            @detection_timeout_ms -> raise "session lock release not received"
          end
        end)
      end)

    holder_monitor = Process.monitor(holder.pid)
    assert_receive {:session_locked, ^barrier, holder_backend}, @detection_timeout_ms

    clients =
      for _lane <- 1..2 do
        task = Task.Supervisor.async_nolink(supervisor, fn -> post_stream!(port, setup, payload, thread_id, false) end)
        {task, Process.monitor(task.pid)}
      end

    try do
      waiters = await_http_lock_waiters!(holder_backend, System.monotonic_time(:millisecond) + @detection_timeout_ms)
      assert length(Enum.uniq(waiters)) == 2
      refute holder_backend in waiters
    after
      send(holder.pid, {:release_session, barrier})
    end

    assert {:ok, :ok} = Task.await(holder, @detection_timeout_ms)
    assert_receive {:DOWN, ^holder_monitor, :process, _, :normal}, @detection_timeout_ms

    results =
      for {task, monitor} <- clients do
        result = Task.await(task, @detection_timeout_ms)
        assert_receive {:DOWN, ^monitor, :process, _, :normal}, @detection_timeout_ms
        result
      end

    assert Enum.sort(Enum.map(results, &elem(&1, 0))) == [200, 409]
    assert [{200, success}] = Enum.filter(results, &(elem(&1, 0) == 200))
    assert success =~ "response.completed"
    assert [{409, refusal}] = Enum.filter(results, &(elem(&1, 0) == 409))
    assert %{"error" => %{"code" => "duplicate_turn"}} = CodexPooler.JSON.decode!(refusal)
    assert FakeUpstream.count(upstream) == 2
    assert [_, %Request{status: "succeeded"} = successor] = pool_requests(setup)
    assert [%RequestClientRetryLink{successor_request_id: successor_id}] = Repo.all(from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^first.id))
    assert successor_id == successor.id
    assert_settled_once!([first.id, successor.id])
  end

  defp await_http_lock_waiters!(holder_backend, deadline) do
    rows = Repo.query!("WITH RECURSIVE waiters(pid) AS (SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)) UNION SELECT activity.pid FROM pg_stat_activity activity JOIN waiters ON waiters.pid = ANY(pg_blocking_pids(activity.pid))) SELECT pid FROM waiters", [holder_backend]).rows

    cond do
      length(rows) == 2 ->
        List.flatten(rows)

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("two independent HTTP session-lock waiters were not observed; count=#{length(rows)}")

      true ->
        receive do
        after
          10 -> :ok
        end

        await_http_lock_waiters!(holder_backend, deadline)
    end
  end

  defp input_done_event(tool_type) do
    type = if tool_type == "custom_tool_call", do: "response.custom_tool_call_input.done", else: "response.function_call_arguments.done"
    {type, %{"type" => type, "item_id" => "ctc_partial", "output_index" => 0, input_field(tool_type) => "synthetic complete input"}}
  end

  defp scenario(mode, arm, events, following \\ [], termination \\ :abrupt) do
    first = if termination == :clean, do: FakeUpstream.sse_stream(events, done: false), else: FakeUpstream.abrupt_close_mid_stream(events)
    upstream = start_upstream(FakeUpstream.strict_sequence([first | following]))
    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    setup = Map.put(setup, :serving_mode, mode)
    port = start_public_endpoint!()
    thread_id = Ecto.UUID.generate()
    {upstream, setup, port, thread_id, native_payload(setup, thread_id, arm)}
  end

  defp assert_cut!(port, setup, payload, thread_id, tool_type, completed_item? \\ false) do
    {first_status, first_body} = post_stream!(port, setup, payload, thread_id)
    assert first_status == 200
    assert first_body =~ delta_type(tool_type)
    assert first_body =~ "response.output_item.done" == completed_item?
    refute first_body =~ "response.completed"
    assert [first] = pool_requests(setup)
    assert {first.status, first.last_error_code, first.transport} == {"failed", "upstream_stream_error", "http_sse"}
    assert %DateTime{} = first.completed_at
    turn = Repo.get_by!(CodexTurn, request_id: first.id)
    assert %DateTime{} = turn.first_visible_output_at
    assert %DateTime{} = turn.completed_at
  end

  defp assert_refused!(port, setup, payload, thread_id) do
    {status, body} = post_stream!(port, setup, payload, thread_id)
    assert status == 409
    assert %{"error" => %{"code" => "duplicate_turn"}} = CodexPooler.JSON.decode!(body)
  end

  defp assert_settled_once!(request_ids) do
    ledger = Repo.all(from(l in LedgerEntry, where: l.request_id in ^request_ids, select: {l.request_id, l.entry_kind}))
    expected = for id <- request_ids, kind <- ["reservation", "settlement", "release"], into: %{}, do: {{id, kind}, 1}
    assert Enum.frequencies(ledger) == expected
  end

  defp apply_negative_state!(request, :expired), do: Repo.update!(Ecto.Changeset.change(request, completed_at: DateTime.add(DateTime.utc_now(), -(partial_retry_contract().retry_window_seconds + 1), :second)))
  defp apply_negative_state!(request, :missing_digest), do: Repo.update!(Ecto.Changeset.change(request, native_client_retry_digest: nil))
  defp apply_negative_state!(request, :changed_epoch), do: Repo.update!(Ecto.Changeset.change(request, native_client_retry_auth_epoch: request.native_client_retry_auth_epoch + 1))
  defp apply_negative_state!(request, :replay_generation), do: Repo.update_all(from(a in Attempt, where: a.request_id == ^request.id), set: [replay_generation: 1])

  defp apply_negative_state!(request, control) when control in [:missing_proof, :poisoned_proof, :incomplete_proof] do
    attempt = Repo.get_by!(Attempt, request_id: request.id)

    metadata =
      case control do
        :missing_proof -> Map.delete(attempt.response_metadata, "native_http_partial_tool")
        :poisoned_proof -> put_in(attempt.response_metadata, ["native_http_partial_tool", "poisoned"], true)
        :incomplete_proof -> put_in(attempt.response_metadata, ["native_http_partial_tool", "parser_complete"], false)
      end

    Repo.update!(Ecto.Changeset.change(attempt, response_metadata: metadata))
  end

  defp apply_negative_state!(_request, _control), do: :ok

  defp control_events(:completed_item), do: [{"response.output_item.done", %{"type" => "response.output_item.done", "output_index" => 0, "item" => %{"type" => "custom_tool_call", "id" => "ctc_partial", "call_id" => "call_partial", "name" => "synthetic_tool", "input" => "synthetic complete input", "status" => "completed"}}}]
  defp control_events(:unknown_event), do: [{"response.synthetic_unknown", %{"type" => "response.synthetic_unknown"}}]
  defp control_events(:malformed_event), do: ["event: response.custom_tool_call_input.delta\ndata: {malformed\n\n"]
  defp control_events(:truncated_event), do: ["event: response.custom_tool_call_input.delta\ndata: {"]

  defp control_events(:oversized_event) do
    limit = StreamProtocol.max_incomplete_sse_block_bytes()
    ["event: response.custom_tool_call_input.delta\ndata: " <> String.duplicate("x", limit + 1)]
  end

  defp control_events(_control), do: []

  defp partial_retry_contract, do: CompatibilityMatrix.by_slug!(:duplicate_turn_fence).duplicate_turn.partial_http_tool_retry

  defp native_payload(setup, thread_id, arm) do
    %{
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_input(arm),
      "stream" => true,
      "store" => false,
      "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "partial-tool-turn", "request_kind" => "turn"})}
    }
  end

  defp native_input(:opening), do: native_text_input("synthetic partial tool retry")
  defp native_input(:tool_continuation), do: native_input(:opening) ++ [%{"type" => "function_call", "id" => "fc_history", "call_id" => "call_history", "name" => "synthetic_tool", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => "call_history", "output" => "synthetic result"}]

  defp post_stream!(port, setup, payload, thread_id, register_cleanup? \\ true) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)
    if register_cleanup?, do: on_exit(fn -> Mint.HTTP.close(conn) end)
    headers = [{"authorization", setup.authorization}, {"content-type", "application/json"}, {"session-id", thread_id}, {"originator", "codex_cli_rs"}]
    headers = if setup.serving_mode == "lite", do: [{"x-openai-internal-codex-responses-lite", "true"} | headers], else: headers
    {:ok, conn, ref} = Mint.HTTP.request(conn, "POST", @path, headers, CodexPooler.JSON.encode!(payload))

    try do
      receive_all(conn, ref, nil, "")
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_all(conn, ref, status, body) do
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @detection_timeout_ms)

    {status, body, done?} =
      Enum.reduce(responses, {status, body, false}, fn
        {:status, ^ref, next_status}, {_, body, done?} -> {next_status, body, done?}
        {:data, ^ref, data}, {status, body, done?} -> {status, body <> data, done?}
        {:done, ^ref}, {status, body, _} -> {status, body, true}
        _, acc -> acc
      end)

    if done?, do: {status, body}, else: receive_all(conn, ref, status, body)
  end

  defp pool_requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))

  defp partial_events(tool_type) do
    [
      {"response.created", %{"type" => "response.created", "response" => %{"id" => "resp_partial_tool", "status" => "in_progress"}}},
      {"response.output_item.added", %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"type" => tool_type, "id" => "ctc_partial", "call_id" => "call_partial", "name" => "synthetic_tool", input_field(tool_type) => "", "status" => "in_progress"}}},
      {delta_type(tool_type), %{"type" => delta_type(tool_type), "item_id" => "ctc_partial", "output_index" => 0, "delta" => "synthetic partial input"}}
    ]
  end

  defp delta_type("custom_tool_call"), do: "response.custom_tool_call_input.delta"
  defp delta_type("function_call"), do: "response.function_call_arguments.delta"
  defp input_field("custom_tool_call"), do: "input"
  defp input_field("function_call"), do: "arguments"

  defp completed_event do
    {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_partial_tool_retry", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}}
  end
end
