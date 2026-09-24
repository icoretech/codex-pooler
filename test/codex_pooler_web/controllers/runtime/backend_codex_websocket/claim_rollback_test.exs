defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ClaimRollbackTest do
  # A native websocket request takes its durable claim (`Accounting.claim_websocket_turn/3`)
  # in its own committed transaction, before the reservation transaction. When
  # the reservation then rolled back -- a database that stopped answering (the
  # retryable 503) or a reservation that raised (the 500 of the active-turn
  # race, findings#206 row 206-310) -- the claim row stayed `accepted` and
  # fenced every resend of the same request with `409 duplicate_turn` until the
  # six-hour stale-claim recovery, which then left it failed and still fenced
  # (findings#206 row 206-331). The claim is now released with the rolled-back
  # reservation, so the released client's resend on a new connection is served
  # once; a claim whose reservation committed, or a predecessor the request
  # chained onto, is never released. The released client's (Codex 0.156.1) key
  # sets and identifiers, synthetic text. One node, websocket, Full, with owner
  # forwarding on and off; the faults are PostgreSQL triggers inside the
  # sandbox transaction every process of the test shares.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [released_client_connect!: 4]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @installation_id "00000000-0000-4000-8000-00000000c331"
  @context_window_id "00000000-0000-4000-8000-00000000c332"
  @turn_endpoint "/backend-api/codex/responses"
  @compact_endpoint "/backend-api/codex/responses/compact"

  @claim_prefixes %{
    opening_turn: "codex-turn:",
    tool_continuation: "codex-request:",
    post_compaction_resume: "codex-resume:",
    full_history_compaction: "codex-request:"
  }

  for shape <- [:opening_turn, :tool_continuation, :post_compaction_resume, :full_history_compaction],
      forwarding <- [:forwarded, :direct],
      fault <- [:database_shutdown, :reservation_raise] do
    @tag shape: shape, forwarding: forwarding, fault: fault
    test "#{shape} #{forwarding}: a claim whose reservation meets #{fault} is released and the resend is served once",
         %{shape: shape, forwarding: forwarding, fault: fault} do
      assert run_rollback(shape, forwarding, fault) == %{
               refused: refusal(fault),
               claim_prefix: @claim_prefixes[shape],
               rows_after_refusal: [],
               retry: :served,
               rows: [{endpoint(shape), "succeeded", @claim_prefixes[shape]}],
               upstream_requests: 1,
               live_rows: 0,
               finalization_failures: 0
             }
    end
  end

  # The chained resend: a tool continuation the provider failed is resent and
  # chained under the derived claim. When that successor's reservation rolls
  # back, only the successor's own claim row goes; the failed predecessor keeps
  # its claim and history, and the next resend chains to it again.
  for forwarding <- [:forwarded, :direct] do
    @tag forwarding: forwarding
    test "#{forwarding}: a chained resend whose reservation rolls back releases only its own claim", %{forwarding: forwarding} do
      assert run_chained_rollback(forwarding) == %{
               predecessor: {"failed", "server_error", :unchanged},
               refused: {503, "service_unavailable"},
               rows_after_refusal: [:predecessor],
               retry: :served,
               successor: {"succeeded", "codex-request-retry:", :chained},
               upstream_requests: 2,
               live_rows: 0
             }
    end
  end

  # The resume of a mid-turn compaction admitted by the native compaction
  # runtime proof takes its `codex-resume:` claim through the same claim path
  # (findings#225 row 225-87). The released client drops the socket after the
  # refusal and resends the resume on a new one, where no admission exists and
  # the same claim is derived again.
  for forwarding <- [:forwarded, :direct], fault <- [:database_shutdown, :reservation_raise] do
    @tag forwarding: forwarding, fault: fault
    test "#{forwarding}: an admitted resume whose reservation meets #{fault} is released and its resend is served once", %{forwarding: forwarding, fault: fault} do
      assert run_admitted_resume_rollback(forwarding, fault) == %{
               refused: refusal(fault),
               rows_after_refusal: [{"succeeded", "codex-turn:"}, {"succeeded", :admitted}],
               retry: :served,
               rows: [{"succeeded", "codex-turn:"}, {"succeeded", :admitted}, {"succeeded", "codex-resume:"}],
               upstream_requests: 3,
               live_rows: 0,
               finalization_failures: 0
             }
    end
  end

  # A reservation that committed is not released: a fault after it (the first
  # attempt's insert) settles the reserved request as a task failure instead,
  # with its reservation released in the ledger.
  for forwarding <- [:forwarded, :direct] do
    @tag forwarding: forwarding
    test "#{forwarding}: a claim whose reservation committed is settled, never released, when the dispatch raises", %{forwarding: forwarding} do
      assert run_committed_reservation_raise(forwarding) == %{
               refused: {500, "websocket_response_task_failed"},
               rows: [{"failed", "owner_task_exception"}],
               ledger: ["release", "reservation"],
               upstream_requests: 0
             }
    end
  end

  defp run_rollback(shape, forwarding, fault) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(FakeUpstream.strict_sequence([served_expectation(shape)]))
    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    frame = frame(shape, setup, thread_id)

    install_fault!(fault)
    {refused, log} = ExUnit.CaptureLog.with_log(fn -> port |> send_once!(setup, thread_id, frame) |> refusal_of() end)
    rows_after_refusal = pool_requests(setup.pool.id)
    claim_prefix = observed_claim_prefix(shape, rows_after_refusal)
    remove_fault!(fault)

    retry = port |> send_once!(setup, thread_id, frame) |> outcome()
    rows = await_settled!(setup.pool.id, 1)

    measured = %{
      refused: refused,
      claim_prefix: claim_prefix,
      rows_after_refusal: Enum.map(rows_after_refusal, &{&1.status, &1.last_error_code, &1.correlation_id}),
      retry: retry,
      rows: Enum.map(rows, &{&1.endpoint, &1.status, claim_prefix(&1.correlation_id)}),
      upstream_requests: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"])),
      finalization_failures: finalization_failures(log)
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-331 #{shape} #{forwarding} #{fault}: #{inspect(measured)}" end)
    if retry == :served, do: assert(:ok = FakeUpstream.verify!(upstream))
    measured
  end

  # The claim prefix the refused request held, read before the fault is
  # removed: the red run leaves its claim row behind, the green run none, so it
  # comes from the successful retry's row when nothing was left.
  defp observed_claim_prefix(shape, [%Request{correlation_id: claim}]) when is_binary(claim), do: claim_prefix(claim) || {shape, :unknown}
  defp observed_claim_prefix(shape, []), do: @claim_prefixes[shape]
  defp observed_claim_prefix(shape, rows), do: {shape, Enum.map(rows, & &1.correlation_id)}

  defp run_chained_rollback(forwarding) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}], respond: provider_failure_frames()),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}], respond: completed_frames("resp_claim_rollback_chained", [answer()]))
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    frame = frame(:tool_continuation, setup, thread_id)

    assert %{"type" => "response.failed"} = send_once!(port, setup, thread_id, frame)
    [predecessor] = await_settled!(setup.pool.id, 1)

    install_fault!(:database_shutdown)
    refused = port |> send_once!(setup, thread_id, frame) |> refusal_of()
    rows_after_refusal = pool_requests(setup.pool.id)
    remove_fault!(:database_shutdown)

    retry = port |> send_once!(setup, thread_id, frame) |> outcome()
    rows = await_settled!(setup.pool.id, 2)
    predecessor_now = Repo.get(Request, predecessor.id)
    successor = Enum.find(rows, &(&1.id != predecessor.id))

    measured = %{
      predecessor: {predecessor_now && predecessor_now.status, predecessor_now && predecessor_now.last_error_code, if(unchanged?(predecessor, predecessor_now), do: :unchanged, else: :changed)},
      refused: refused,
      rows_after_refusal: Enum.map(rows_after_refusal, &if(&1.id == predecessor.id, do: :predecessor, else: {&1.status, &1.correlation_id})),
      retry: retry,
      successor: successor && {successor.status, claim_prefix(successor.correlation_id), if(chained?(successor, predecessor), do: :chained, else: :unchained)},
      upstream_requests: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"]))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-331 chained #{forwarding}: #{inspect(measured)}" end)
    if retry == :served, do: assert(:ok = FakeUpstream.verify!(upstream))
    measured
  end

  defp run_admitted_resume_rollback(forwarding, fault) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    turn_id = "#{thread_id}-turn"

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, forbidden: ["previous_response_id"]], respond: completed_frames("resp_claim_rollback_anchor", [])),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [valid: true, equals: %{"previous_response_id" => "resp_claim_rollback_anchor", "input.0.type" => "function_call_output"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => compaction_item()}),
                CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_claim_rollback_compact", "status" => "completed", "output" => [compaction_item()], "usage" => usage()}})
              ])
          ),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, forbidden: ["previous_response_id"]], respond: completed_frames("resp_claim_rollback_resumed", []))
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    client = released_client_connect!(port, setup.authorization, thread_id, "#{thread_id}:0")

    {refused, log, rows_after_refusal} =
      try do
        anchor = resume_rig_frame(setup, [prompt()], nil, resume_rig_metadata(thread_id, turn_id, 0, :turn))
        {client, "response.completed"} = send_terminal!(client, anchor)

        compact =
          resume_rig_frame(
            setup,
            [%{"type" => "function_call_output", "call_id" => "call_claim_rollback", "output" => "ok"}, %{"type" => "compaction_trigger"}],
            "resp_claim_rollback_anchor",
            resume_rig_metadata(thread_id, turn_id, 0, :compaction)
          )

        {client, "response.completed"} = send_terminal!(client, compact)
        _settled = await_settled!(setup.pool.id, 2)

        install_fault!(fault)
        {{_client, terminal}, log} = ExUnit.CaptureLog.with_log(fn -> send_terminal!(client, resume_rig_frame(setup, [compaction_item()], nil, resume_rig_metadata(thread_id, turn_id, 1, :turn)), :frame) end)
        {refusal_of(terminal), log, await_settled!(setup.pool.id, 2)}
      after
        Mint.HTTP.close(client.conn)
      end

    remove_fault!(fault)
    resume = resume_rig_frame(setup, [compaction_item()], nil, resume_rig_metadata(thread_id, turn_id, 1, :turn))
    second = released_client_connect!(port, setup.authorization, thread_id, "#{thread_id}:1")

    retry =
      try do
        {_second, terminal} = send_terminal!(second, resume, :frame)
        outcome(terminal)
      after
        Mint.HTTP.close(second.conn)
      end

    rows = await_settled!(setup.pool.id, 3)

    measured = %{
      refused: refused,
      rows_after_refusal: Enum.map(rows_after_refusal, &resume_rig_row/1),
      retry: retry,
      rows: Enum.map(rows, &resume_rig_row/1),
      upstream_requests: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"])),
      finalization_failures: finalization_failures(log)
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-331 admitted_resume #{forwarding} #{fault}: #{inspect(measured)}" end)
    if retry == :served, do: assert(:ok = FakeUpstream.verify!(upstream))
    measured
  end

  # The anchored compaction is admitted under its runtime-proof claim, whose
  # prefix is not the question here.
  defp resume_rig_row(%Request{endpoint: @compact_endpoint, status: status}), do: {status, :admitted}
  defp resume_rig_row(%Request{status: status, correlation_id: claim}), do: {status, claim_prefix(claim) || claim}

  defp send_terminal!(client, frame, shape \\ :type) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame)
    {conn, websocket, terminal} = receive_terminal_with_state!(conn, websocket, client.ref)
    client = %{client | conn: conn, websocket: websocket}
    if shape == :type, do: {client, terminal["type"]}, else: {client, terminal}
  end

  defp receive_terminal_with_state!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_terminal_with_state!(conn, websocket, ref)
    end
  end

  defp resume_rig_frame(setup, input, previous_response_id, metadata) do
    %{"type" => "response.create", "model" => setup.model.exposed_model_id, "stream" => true, "input" => input, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}
    |> then(&if previous_response_id, do: Map.put(&1, "previous_response_id", previous_response_id), else: &1)
    |> CodexPooler.JSON.encode!()
  end

  defp resume_rig_metadata(thread_id, turn_id, window_number, kind) do
    document = %{
      "turn_id" => turn_id,
      "thread_id" => thread_id,
      "session_id" => thread_id,
      "window_id" => "#{thread_id}:#{window_number}",
      "context_window_id" => "00000000-0000-4000-8000-00000000#{window_number}c33",
      "window_number" => window_number,
      "request_kind" => Atom.to_string(kind)
    }

    document =
      if kind == :compaction,
        do: Map.put(document, "compaction", %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "mid_turn", "strategy" => "memento"}),
        else: document

    CodexPooler.JSON.encode!(document)
  end

  # The task-exception finalizer used to fail on a row holding nothing but the
  # claim (`Ecto.NoResultsError`), and a release that fails logs its own line.
  defp finalization_failures(log) do
    length(Regex.scan(~r/exception finalization failed|turn claim release failed/, log))
  end

  defp run_committed_reservation_raise(forwarding) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_claim_rollback_never_dispatched"}))
    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()

    install_fault!(:attempt_raise)
    refused = port |> send_once!(setup, thread_id, frame(:opening_turn, setup, thread_id)) |> refusal_of()
    rows = await_settled!(setup.pool.id, 1)
    remove_fault!(:attempt_raise)

    %{
      refused: refused,
      rows: Enum.map(rows, &{&1.status, &1.last_error_code}),
      ledger: rows |> Enum.flat_map(&ledger_kinds/1) |> Enum.sort(),
      upstream_requests: FakeUpstream.count(upstream)
    }
  end

  defp refusal(:database_shutdown), do: {503, "service_unavailable"}
  defp refusal(:reservation_raise), do: {500, "websocket_response_task_failed"}

  defp endpoint(:full_history_compaction), do: @compact_endpoint
  defp endpoint(_shape), do: @turn_endpoint

  # PostgreSQL ends in-flight statements with `57P01 admin_shutdown` when the
  # instance stops; the reservation's ledger insert is the first write the
  # claim does not make. The active-turn index conflict is the reservation
  # raise the resend race produced (findings#206 row 206-310). The attempt
  # insert comes after the reservation committed.
  defp install_fault!(:database_shutdown) do
    Repo.query!("CREATE FUNCTION pg_temp.p89_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'terminating connection due to administrator command' USING ERRCODE = 'admin_shutdown'; END $$")
    Repo.query!("CREATE TRIGGER p89_fault BEFORE INSERT ON ledger_entries FOR EACH ROW EXECUTE FUNCTION pg_temp.p89_fault()")
  end

  defp install_fault!(:reservation_raise) do
    Repo.query!("CREATE FUNCTION pg_temp.p89_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'duplicate key value violates unique constraint' USING ERRCODE = 'unique_violation', CONSTRAINT = 'codex_turns_active_semantic_turn_uq'; END $$")
    Repo.query!("CREATE TRIGGER p89_fault BEFORE INSERT ON codex_turns FOR EACH ROW EXECUTE FUNCTION pg_temp.p89_fault()")
  end

  defp install_fault!(:attempt_raise) do
    Repo.query!("CREATE FUNCTION pg_temp.p89_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic attempt fault' USING ERRCODE = 'raise_exception'; END $$")
    Repo.query!("CREATE TRIGGER p89_fault BEFORE INSERT ON attempts FOR EACH ROW EXECUTE FUNCTION pg_temp.p89_fault()")
  end

  defp remove_fault!(:database_shutdown), do: Repo.query!("DROP TRIGGER p89_fault ON ledger_entries")
  defp remove_fault!(:reservation_raise), do: Repo.query!("DROP TRIGGER p89_fault ON codex_turns")
  defp remove_fault!(:attempt_raise), do: Repo.query!("DROP TRIGGER p89_fault ON attempts")

  # One request on its own connection, as the released client sends a retry:
  # a new connection and the same body.
  defp send_once!(port, setup, thread_id, frame) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      receive_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> terminal
      _progress -> receive_terminal!(conn, websocket, ref)
    end
  end

  defp refusal_of(%{"type" => "error", "status" => status, "error" => %{"code" => code}}), do: {status, code}
  defp refusal_of(other), do: {:not_refused, other["type"]}

  defp outcome(%{"type" => "response.completed"}), do: :served
  defp outcome(terminal), do: refusal_of(terminal)

  defp served_expectation(:full_history_compaction) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
      respond:
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => compaction_item()}),
          CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_claim_rollback_compact", "status" => "completed", "output" => [compaction_item()], "usage" => usage()}})
        ])
    )
  end

  defp served_expectation(_shape) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
      respond: completed_frames("resp_claim_rollback_served", [answer()])
    )
  end

  # The unanchored forms the released client resends byte-identically on a new
  # connection: a turn's opening request, a tool-result round and the resume
  # after a mid-turn compaction as full history, and a remote compaction as
  # full history ending in its trigger.
  defp frame(shape, setup, thread_id) do
    turn_id = "#{thread_id}-turn"

    {input, metadata} =
      case shape do
        :opening_turn ->
          {[prompt()], %{"request_kind" => "turn"}}

        :tool_continuation ->
          {[prompt(), function_call(), function_call_output()], %{"request_kind" => "turn"}}

        :post_compaction_resume ->
          {[prompt(), compaction_item()], %{"request_kind" => "turn"}}

        :full_history_compaction ->
          compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "pre_turn", "strategy" => "memento"}
          {[prompt(), answer(), %{"type" => "compaction_trigger"}], %{"request_kind" => "compaction", "compaction" => compaction}}
      end

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => input,
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "text" => %{"verbosity" => "low"},
      "prompt_cache_key" => thread_id,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => turn_id,
        "root_turn_id" => turn_id,
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => "#{thread_id}:0",
        "x-codex-turn-metadata" => turn_metadata(thread_id, turn_id, metadata)
      }
    })
  end

  defp turn_metadata(thread_id, turn_id, extra) do
    %{
      "agent_name" => "/root",
      "context_window_id" => @context_window_id,
      "installation_id" => @installation_id,
      "root_turn_id" => turn_id,
      "sandbox" => "seatbelt",
      "sandbox_mode" => "read-only",
      "session_id" => thread_id,
      "thread_id" => thread_id,
      "turn_id" => turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "window_id" => "#{thread_id}:0",
      "window_number" => 0,
      "model" => "gpt-test-model",
      "reasoning_effort" => "low"
    }
    |> Map.merge(extra)
    |> CodexPooler.JSON.encode!()
  end

  defp prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic claim rollback prompt"}]}
  defp answer, do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}
  defp function_call, do: %{"type" => "function_call", "call_id" => "call_claim_rollback", "name" => "shell", "arguments" => "{}"}
  defp function_call_output, do: %{"type" => "function_call_output", "call_id" => "call_claim_rollback", "output" => "synthetic tool output"}
  defp compaction_item, do: %{"type" => "compaction", "encrypted_content" => "synthetic-claim-rollback-summary"}
  defp usage, do: %{"input_tokens" => 20, "output_tokens" => 2, "total_tokens" => 22}

  defp completed_frames(response_id, output) do
    FakeUpstream.websocket_text_frames(
      [CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}})] ++
        Enum.map(output, &CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => &1})) ++
        [CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => usage()}})]
    )
  end

  # provenance: observed runbook terminal-failure resend (response.failed server_error)
  defp provider_failure_frames do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_claim_rollback_failed", "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.failed", "response" => %{"id" => "resp_claim_rollback_failed", "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}})
    ])
  end

  defp claim_prefix(claim) when is_binary(claim) do
    Enum.find(["codex-request-retry:", "codex-turn:", "codex-request:", "codex-resume:"], &String.starts_with?(claim, &1))
  end

  defp claim_prefix(_claim), do: nil

  defp unchanged?(%Request{} = before, %Request{} = now),
    do: Map.take(before, [:status, :correlation_id, :completed_at, :last_error_code]) == Map.take(now, [:status, :correlation_id, :completed_at, :last_error_code])

  defp unchanged?(_before, _now), do: false

  defp chained?(%Request{request_metadata: %{"client_resend" => %{"predecessor_request_id" => id}}}, %Request{id: id}), do: true
  defp chained?(%Request{id: successor_id}, %Request{id: predecessor_id}), do: Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^successor_id and link.predecessor_request_id == ^predecessor_id))

  defp ledger_kinds(%Request{id: request_id}), do: Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request_id, select: entry.entry_kind))

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id]))

  # The socket writes the terminal before the task settles its rows; poll the
  # rows within a detection budget.
  defp await_settled!(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> pool_requests(pool_id) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) and no_live_attempt?(rows) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp no_live_attempt?(rows) do
    ids = Enum.map(rows, & &1.id)
    not Repo.exists?(from(attempt in Attempt, where: attempt.request_id in ^ids and attempt.status in ["queued", "in_progress"]))
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
