defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ClaimFenceReleaseTest do
  # A native websocket request takes its durable claim (`Accounting.claim_websocket_turn/3`)
  # in its own committed transaction, before the reservation. Three ways of
  # ending such a claim before anything reached the provider used to leave a row
  # that held the claim for good, so every resend of the request met a
  # permanent `409 duplicate_turn`:
  #
  # - a refusal at the reservation (the key's active-request cap "retry
  #   shortly", a token window, no eligible backend) rewrote the claim row to
  #   `rejected` under the claim (findings#206 row 206-420);
  # - a client that left between the claim and the reservation had the row
  #   closed `failed client_disconnected` by the socket's direct interrupt,
  #   which the resend policy never admits without a turn (row 206-419);
  # - the six-hour stale-claim recovery (row 206-421, `claim_fence_release_test`
  #   in `test/codex_pooler/accounting`).
  #
  # Each now keeps its row as history under a fresh correlation id and gives the
  # claim up, so the resend is served once. The released client's (Codex
  # 0.156.1) key sets and identifiers, synthetic text. One node, websocket,
  # Full, owner forwarding on and off, FakeUpstream.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo

  @moduletag capture_log: true

  # The receipt-identity refusal and the release line are `info`.
  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  @installation_id "00000000-0000-4000-8000-00000000c420"
  @context_window_id "00000000-0000-4000-8000-00000000c421"
  @turn_endpoint "/backend-api/codex/responses"

  @claim_prefixes %{opening_turn: "codex-turn:", tool_continuation: "codex-request:"}

  @refusals %{
    concurrency_cap: {429, "api_key_concurrency_limit_exceeded"},
    # A window refusal is a 429, like the cap (findings#206 row 206-427).
    token_window: {429, "api_key_policy_limit_exceeded"},
    open_circuit: {503, "no_eligible_backend"}
  }

  # 206-420: a refusal made at the reservation, after the claim, before any
  # attempt. The refused row stays as the refusal's history; the claim goes.
  for {refusal, shapes} <- [concurrency_cap: [:opening_turn, :tool_continuation], token_window: [:opening_turn], open_circuit: [:opening_turn]],
      shape <- shapes,
      forwarding <- [:forwarded, :direct] do
    @tag refusal: refusal, shape: shape, forwarding: forwarding
    test "#{shape} #{forwarding}: a claimed turn refused at the reservation by #{refusal} is resent and served once",
         %{refusal: refusal, shape: shape, forwarding: forwarding} do
      {status, code} = @refusals[refusal]

      assert run_refusal(refusal, shape, forwarding) == %{
               refused: {status, code},
               rows_after_refusal: [{"rejected", code, :claim_given_up}],
               retry: :served,
               rows: [{"rejected", code, :claim_given_up}, {"succeeded", nil, @claim_prefixes[shape]}],
               upstream_requests: 1,
               live_rows: 0,
               receipt_identity_refusals: 0,
               claim_released_lines: 1
             }
    end
  end

  # 206-420, chained: a resend chained onto a provider failure and refused at
  # its reservation gives up only its own claim and its own client-retry link;
  # the predecessor is untouched and the next resend chains onto it again. With
  # owner forwarding on the resend is chained by the owner's client-retry
  # preflight under a `client-retry-v1:` claim instead.
  for forwarding <- [:forwarded, :direct] do
    @tag forwarding: forwarding
    test "#{forwarding}: a chained resend refused at the reservation gives up its own claim and the next resend chains again", %{forwarding: forwarding} do
      successor_claim = if forwarding == :forwarded, do: "client-retry-v1:", else: "codex-request-retry:"

      assert run_chained_refusal(forwarding) == %{
               predecessor: {"failed", "server_error", :unchanged},
               refused: {429, "api_key_concurrency_limit_exceeded"},
               refused_row: {"rejected", :claim_given_up, :unlinked},
               retry: :served,
               successor: {"succeeded", successor_claim, :chained},
               upstream_requests: 2,
               live_rows: 0
             }
    end
  end

  # 206-419: the claim-only row the socket's direct interrupt closes when the
  # client leaves before the reservation. The reservation is refused `503`
  # while the database fails, and the claim release that follows fails too
  # (`websocket turn claim release failed`), so the claim is still only a claim
  # when the client drops the socket: exactly the row production shows (206-418).
  for forwarding <- [:forwarded, :direct] do
    @tag forwarding: forwarding
    test "#{forwarding}: a claim-only row closed by the client's disconnect is resent and served once", %{forwarding: forwarding} do
      assert run_claim_only_disconnect(forwarding) == %{
               refused: {503, "service_unavailable"},
               release_failures: 1,
               receipt_identity_refusals: 0,
               claim_released_lines: 1,
               closed_row: {"failed", "client_disconnected", 499, :claim_given_up},
               retry: :served,
               rows: [{"failed", "client_disconnected", :claim_given_up}, {"succeeded", nil, "codex-turn:"}],
               upstream_requests: 1,
               live_rows: 0
             }
    end
  end

  defp run_refusal(refusal, shape, forwarding) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(FakeUpstream.strict_sequence([served_expectation("resp_claim_fence_served")]))
    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    frame = frame(shape, setup, thread_id)

    lifted = impose_refusal!(refusal, setup)

    {{refused, rows_after_refusal}, log} =
      ExUnit.CaptureLog.with_log(fn ->
        refused = port |> send_once!(setup, thread_id, frame) |> refusal_of()
        {refused, await_settled!(setup.pool.id, 1, &websocket?/1)}
      end)

    lifted.()

    retry = port |> send_once!(setup, thread_id, frame) |> outcome()
    rows = await_settled!(setup.pool.id, 2, &websocket?/1)

    measured = %{
      refused: refused,
      rows_after_refusal: Enum.map(rows_after_refusal, &row/1),
      retry: retry,
      rows: Enum.map(rows, &row/1),
      upstream_requests: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"])),
      receipt_identity_refusals: receipt_identity_refusals(log),
      claim_released_lines: length(Regex.scan(~r/websocket turn claim released request_id=\S+ release_reason=reservation_refused/, log))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-420 #{refusal} #{shape} #{forwarding}: #{inspect(measured)}" end)
    if retry == :served, do: assert(:ok = FakeUpstream.verify!(upstream))
    measured
  end

  defp run_chained_refusal(forwarding) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}], respond: provider_failure_frames()),
          served_expectation("resp_claim_fence_chained")
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    frame = frame(:opening_turn, setup, thread_id)

    assert %{"type" => "response.failed"} = send_once!(port, setup, thread_id, frame)
    [predecessor] = await_settled!(setup.pool.id, 1, &websocket?/1)

    lifted = impose_refusal!(:concurrency_cap, setup)
    refused = port |> send_once!(setup, thread_id, frame) |> refusal_of()
    refused_row = setup.pool.id |> await_settled!(2, &websocket?/1) |> Enum.find(&(&1.id != predecessor.id))
    lifted.()

    retry = port |> send_once!(setup, thread_id, frame) |> outcome()
    rows = await_settled!(setup.pool.id, 3, &websocket?/1)
    predecessor_now = Repo.get(Request, predecessor.id)
    successor = Enum.find(rows, &(&1.id != predecessor.id and &1.status == "succeeded"))

    measured = %{
      predecessor: {predecessor_now.status, predecessor_now.last_error_code, if(unchanged?(predecessor, predecessor_now), do: :unchanged, else: :changed)},
      refused: refused,
      refused_row: refused_row && {refused_row.status, claim_state(refused_row.correlation_id), if(linked?(refused_row), do: :linked, else: :unlinked)},
      retry: retry,
      successor: successor && {successor.status, claim_prefix(successor.correlation_id), if(chained?(successor, predecessor), do: :chained, else: :unchained)},
      upstream_requests: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"]))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-420 chained #{forwarding}: #{inspect(measured)}" end)
    if retry == :served, do: assert(:ok = FakeUpstream.verify!(upstream))
    measured
  end

  defp run_claim_only_disconnect(forwarding) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(FakeUpstream.strict_sequence([served_expectation("resp_claim_fence_after_disconnect")]))
    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    frame = frame(:opening_turn, setup, thread_id)

    install_faults!()

    # The disconnect cleanup runs after the close; the log is read once it
    # settled the row.
    {{refused, [closed]}, log} =
      ExUnit.CaptureLog.with_log(fn ->
        refused = port |> send_once!(setup, thread_id, frame) |> refusal_of()
        {refused, await_settled!(setup.pool.id, 1, &websocket?/1)}
      end)

    remove_faults!()

    retry = port |> send_once!(setup, thread_id, frame) |> outcome()
    rows = await_settled!(setup.pool.id, 2, &websocket?/1)

    measured = %{
      refused: refused,
      release_failures: length(Regex.scan(~r/turn claim release failed/, log)),
      receipt_identity_refusals: receipt_identity_refusals(log),
      claim_released_lines: length(Regex.scan(~r/websocket turn claim released request_id=\S+ release_reason=client_left_before_reservation/, log)),
      closed_row: {closed.status, closed.last_error_code, closed.response_status_code, claim_state(closed.correlation_id)},
      retry: retry,
      rows: Enum.map(rows, &row/1),
      upstream_requests: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"]))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-419 #{forwarding}: #{inspect(measured)}" end)
    if retry == :served, do: assert(:ok = FakeUpstream.verify!(upstream))
    measured
  end

  # The key's active-request cap is taken by another request of the same key
  # (a reservation left outstanding) and freed by settling it.
  defp impose_refusal!(:concurrency_cap, setup) do
    Repo.update_all(from(key in CodexPooler.Access.APIKey, where: key.id == ^setup.api_key.id), set: [max_active_requests: 1])
    {:ok, auth} = CodexPooler.Access.authenticate_authorization_header(setup.authorization)

    {:ok, %{request: holder}} =
      Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10}, %{correlation_id: "claim-fence-holder-#{System.unique_integer([:positive])}"})

    fn ->
      {:ok, _settled} =
        Accounting.finalize_reserved_request_failure(holder, %{request_status: "failed", response_status_code: 499, last_error_code: "client_disconnected", usage_status: "not_applicable"})
    end
  end

  # A daily token window exhausted by another request of the same key (a
  # reservation left outstanding), then lifted. A window below the request's
  # own estimate would be a per-request 400 instead (findings#206 row 206-448).
  defp impose_refusal!(:token_window, setup) do
    holder = CodexPooler.AccountingTestSupport.hold_key_reservation!(setup.authorization, setup.model, 10_000, "claim-fence-holder")
    {1, _} = Repo.update_all(from(binding in APIKeyPolicyBinding, where: binding.api_key_id == ^setup.api_key.id), set: [status: "active", max_tokens_per_day: 10_000])

    fn ->
      CodexPooler.AccountingTestSupport.release_key_reservation!(holder)
      Repo.update_all(from(binding in APIKeyPolicyBinding, where: binding.api_key_id == ^setup.api_key.id), set: [max_tokens_per_day: nil])
    end
  end

  # The only assignment's circuit is open when routing runs after the claim,
  # then closed again.
  defp impose_refusal!(:open_circuit, setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    circuits =
      for route_class <- [CodexPooler.RouteClass.proxy_websocket(), CodexPooler.RouteClass.proxy_stream(), CodexPooler.RouteClass.proxy_http()],
          model_identifier <- Enum.uniq([setup.model.upstream_model_id, setup.model.exposed_model_id]) do
        Repo.insert!(%RoutingCircuitState{
          pool_id: setup.pool.id,
          pool_upstream_assignment_id: setup.assignment.id,
          upstream_identity_id: setup.assignment.upstream_identity_id,
          model_identifier: model_identifier,
          route_class: route_class,
          status: "open",
          reason_code: "synthetic_circuit_reason",
          failure_count: 3,
          success_count: 0,
          opened_at: now,
          next_probe_at: DateTime.add(now, 3_600, :second),
          last_failure_at: now,
          metadata: %{},
          created_at: now,
          updated_at: now
        })
      end

    fn -> Enum.each(circuits, &Repo.delete!/1) end
  end

  # The reservation's ledger insert meets `57P01` (the retryable 503), and the
  # claim release after it meets a failing database as well.
  defp install_faults! do
    Repo.query!("CREATE FUNCTION pg_temp.p93_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'terminating connection due to administrator command' USING ERRCODE = 'admin_shutdown'; END $$")
    Repo.query!("CREATE TRIGGER p93_ledger_fault BEFORE INSERT ON ledger_entries FOR EACH ROW EXECUTE FUNCTION pg_temp.p93_fault()")
    Repo.query!("CREATE TRIGGER p93_release_fault BEFORE DELETE ON requests FOR EACH ROW EXECUTE FUNCTION pg_temp.p93_fault()")
  end

  defp remove_faults! do
    Repo.query!("DROP TRIGGER p93_ledger_fault ON ledger_entries")
    Repo.query!("DROP TRIGGER p93_release_fault ON requests")
  end

  # One request on its own connection, as the released client sends a retry:
  # a new connection and the same body. Closing the connection is the client's
  # disconnect.
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

  # A row that gave its claim up must still be recognised by the socket's
  # cleanup receipt, which names the claim it bound.
  defp receipt_identity_refusals(log), do: length(Regex.scan(~r/refused_clause=receipt_identity/, log))

  defp refusal_of(%{"type" => "error", "status" => status, "error" => %{"code" => code}}), do: {status, code}
  defp refusal_of(other), do: {:not_refused, other["type"]}

  defp outcome(%{"type" => "response.completed"}), do: :served
  defp outcome(terminal), do: refusal_of(terminal)

  defp served_expectation(response_id) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
      respond: completed_frames(response_id, [answer()])
    )
  end

  defp frame(shape, setup, thread_id) do
    turn_id = "#{thread_id}-turn"

    input =
      case shape do
        :opening_turn -> [prompt()]
        :tool_continuation -> [prompt(), function_call(), function_call_output()]
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
        "x-codex-turn-metadata" => turn_metadata(thread_id, turn_id)
      }
    })
  end

  defp turn_metadata(thread_id, turn_id) do
    CodexPooler.JSON.encode!(%{
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
      "reasoning_effort" => "low",
      "request_kind" => "turn"
    })
  end

  defp prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic claim fence prompt"}]}
  defp answer, do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}
  defp function_call, do: %{"type" => "function_call", "call_id" => "call_claim_fence", "name" => "shell", "arguments" => "{}"}
  defp function_call_output, do: %{"type" => "function_call_output", "call_id" => "call_claim_fence", "output" => "synthetic tool output"}
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
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_claim_fence_failed", "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.failed", "response" => %{"id" => "resp_claim_fence_failed", "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}})
    ])
  end

  defp row(%Request{status: "succeeded", correlation_id: claim}), do: {"succeeded", nil, claim_prefix(claim) || claim}
  defp row(%Request{status: status, last_error_code: code, correlation_id: claim}), do: {status, code, claim_state(claim)}

  # A row that still holds a request claim names it; one that gave it up
  # carries a generated id.
  defp claim_state(claim) do
    case claim_prefix(claim) do
      nil -> if match?({:ok, _uuid}, Ecto.UUID.cast(claim)), do: :claim_given_up, else: {:unexpected, claim}
      prefix -> {:holds, prefix}
    end
  end

  defp claim_prefix(claim) when is_binary(claim) do
    Enum.find(["client-retry-v1:", "codex-request-retry:", "codex-turn:", "codex-request:", "codex-resume:"], &String.starts_with?(claim, &1))
  end

  defp claim_prefix(_claim), do: nil

  defp websocket?(%Request{transport: transport}), do: transport == "websocket"

  defp unchanged?(%Request{} = before, %Request{} = now),
    do: Map.take(before, [:status, :correlation_id, :completed_at, :last_error_code]) == Map.take(now, [:status, :correlation_id, :completed_at, :last_error_code])

  defp linked?(%Request{id: id}), do: Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^id or link.predecessor_request_id == ^id))

  defp chained?(%Request{id: successor_id}, %Request{id: predecessor_id}),
    do: Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^successor_id and link.predecessor_request_id == ^predecessor_id))

  defp pool_requests(pool_id, filter), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id])) |> Enum.filter(filter)

  # The socket writes the terminal before the task, or the socket's cleanup,
  # settles its rows; poll the rows within a detection budget.
  defp await_settled!(pool_id, count, filter) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> pool_requests(pool_id, filter) end)
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
