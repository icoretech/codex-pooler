defmodule CodexPooler.Accounting.MailboxOrdinaryTurnChainTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.Gateway.Payloads.{NativeMailboxContinuation, NativeTurnContinuation, RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  setup do
    setup = accounting_setup()
    session = insert_session!(setup)
    semantic = :crypto.strong_rand_bytes(32)
    payload = payload(setup.model.exposed_model_id)
    assert NativeTurnContinuation.turn_role(payload) == :opening
    claim = "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    %{fixture: %{setup: setup, session: session, semantic: semantic, claim: claim, payload: payload}}
  end

  for transport <- ["websocket", "http_sse"] do
    test "two mailbox cuts of a #{transport} opener chain under the turn claim", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(transport))
      first_output = commentary("first")
      cut!(fixture, original, first_output)
      first_payload = append(fixture.payload, [first_output, mailbox(1), mailbox(2)])
      assert NativeTurnContinuation.turn_role(first_payload) == :opening
      first = admit!(fixture, first_payload, unquote(transport))
      assert_edge!(original, first)

      second_output = reasoning("second")
      cut!(fixture, first, second_output)
      expire!(original)
      second_payload = append(first_payload, [second_output, mailbox(3)])
      second = admit!(fixture, second_payload, unquote(transport))
      assert_edge!(first, second)

      assert original.correlation_id == fixture.claim
      assert counts(fixture) == %{requests: 3, attempts: 2, turns: 2, links: 2, settlements: 2}
      assert Repo.get!(Request, first.id).native_client_retry_digest == witness(fixture, first_payload, unquote(transport)).digest
    end
  end

  test "a websocket opener's mailbox resend falls back to HTTPS as one successor", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    output = commentary("first")
    cut!(fixture, original, output)
    successor = admit!(fixture, append(fixture.payload, [output, mailbox(1)]), "http_sse")
    assert_edge!(original, successor)
    assert counts(fixture) == %{requests: 2, attempts: 1, turns: 1, links: 1, settlements: 1}
  end

  test "an HTTP opener proves the client's re-serialized items by their completed-item identities", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "http_sse")
    delivered = Map.merge(commentary("first"), %{"status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic commentary first", "annotations" => [], "logprobs" => []}]})
    cut!(fixture, original, delivered)
    resent = commentary("first")
    refute progress(resent) == progress(delivered)

    successor = admit!(fixture, append(fixture.payload, [resent, mailbox(1)]), "http_sse")
    assert_edge!(original, successor)
  end

  for transport <- ["websocket", "http_sse"] do
    test "changed-output and output-only #{transport} opener resends keep the fence", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(transport))
      output = commentary("first")
      cut!(fixture, original, output)

      assert_refused!(fixture, append(fixture.payload, [commentary("changed"), mailbox(1)]), unquote(transport), :terminal_predecessor)
      assert_refused!(fixture, append(fixture.payload, [output, reasoning("extra"), mailbox(1)]), unquote(transport), :terminal_predecessor)
      assert_refused!(fixture, append(fixture.payload, [mailbox(1)]), unquote(transport), :terminal_predecessor)

      candidate = append(fixture.payload, [output, mailbox(1)])
      successor = admit!(fixture, candidate, unquote(transport))
      assert_edge!(original, successor)
      # A websocket resend never redeems a native HTTP predecessor.
      assert_refused!(fixture, candidate, "websocket", if(unquote(transport) == "websocket", do: :active_predecessor, else: :authorization_changed))
      assert_refused!(fixture, candidate, "http_sse", :active_predecessor)
      # Once the successor is cut in turn, its identical resend is chained to it.
      cut!(fixture, successor, reasoning("second"))
      assert_edge!(successor, admit!(fixture, candidate, unquote(transport)))
    end
  end

  # An identical resend inside the retry window is served as the cut opener's
  # successor, like any identical resend after an unread response.
  for transport <- ["websocket", "http_sse"] do
    test "a byte-identical #{transport} opener resend is chained", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(transport))
      cut!(fixture, original, commentary("first"))
      successor = admit!(fixture, fixture.payload, unquote(transport))
      assert_edge!(original, successor)
      assert counts(fixture) == %{requests: 2, attempts: 1, turns: 1, links: 1, settlements: 1}
    end
  end

  test "a final-answer message is not a mailbox preemption", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    output = Map.put(commentary("final"), "phase", "final_answer")
    cut!(fixture, original, output)
    assert_refused!(fixture, append(fixture.payload, [output, mailbox(1)]), "websocket", :terminal_predecessor)
  end

  # A call the stream opened and never completed was never run by the client.
  test "an HTTP opener cut with a client-side call still open admits one mailbox continuation", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "http_sse")
    output = commentary("first")
    cut!(fixture, original, output, open_tool_call: true)
    candidate = append(fixture.payload, [output, mailbox(1)])
    assert_refused!(fixture, candidate, "websocket", :authorization_changed)
    assert_refused!(fixture, append(fixture.payload, [commentary("changed"), mailbox(1)]), "http_sse", :terminal_predecessor)
    successor = admit!(fixture, candidate, "http_sse")
    assert_edge!(original, successor)
    assert_refused!(fixture, candidate, "http_sse", :active_predecessor)
  end

  test "an HTTP opener without recorded progress keeps the fence", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "http_sse")
    output = commentary("first")
    cut!(fixture, original, output, progress: false)
    assert_refused!(fixture, append(fixture.payload, [output, mailbox(1)]), "http_sse", :terminal_predecessor)
  end

  # A native HTTP request whose row never completed is stepped over by the
  # turn-chain walk on purpose (a node killed mid-stream), so only its attempt
  # and turn are live rows here.
  for {live_row, transport} <- [request: "websocket", attempt: "websocket", turn: "websocket", attempt: "http_sse", turn: "http_sse"] do
    test "a live #{transport} #{live_row} retains the duplicate fence", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(transport))
      output = commentary("first")
      cut!(fixture, original, output)
      make_live!(original, unquote(live_row))
      assert_refused!(fixture, append(fixture.payload, [output, mailbox(1)]), unquote(transport), :active_predecessor)
    end
  end

  for transport <- ["websocket", "http_sse"] do
    test "an expired #{transport} opener retains the fence", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(transport))
      output = commentary("first")
      cut!(fixture, original, output)
      expire!(original)
      assert_refused!(fixture, append(fixture.payload, [output, mailbox(1)]), unquote(transport), :retry_expired)
    end

    test "a replayed #{transport} opener generation retains the fence", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(transport))
      output = commentary("first")
      cut!(fixture, original, output)
      Repo.update_all(from(a in Attempt, where: a.request_id == ^original.id), set: [replay_generation: 1])
      assert_refused!(fixture, append(fixture.payload, [output, mailbox(1)]), unquote(transport), :terminal_predecessor)
    end

    test "an anchored #{transport} opener resend retains the fence", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(transport))
      output = commentary("first")
      cut!(fixture, original, output)
      anchored = Map.put(append(fixture.payload, [output, mailbox(1)]), "previous_response_id", "resp_synthetic")
      assert NativeMailboxContinuation.attach(witness(fixture, fixture.payload, unquote(transport)), fixture.semantic, anchored, RequestOptions.build(%{}, @endpoint, %{})).mailbox == []
      assert_refused_opts!(fixture, anchored, Map.put(options(fixture, anchored, unquote(transport)), :anchor_present?, true), unquote(transport), :anchor_unavailable)
      assert_refused_opts!(fixture, anchored, options(fixture, anchored, unquote(transport)), unquote(transport), :terminal_predecessor)
    end
  end

  test "a foreign successor link on an HTTP opener retains the fence", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "http_sse")
    output = commentary("first")
    cut!(fixture, original, output)
    foreign = admit!(%{fixture | claim: "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}, fixture.payload, "websocket")
    ClientRetry.insert_link!(original, foreign, db_now())
    assert_refused!(fixture, append(fixture.payload, [output, mailbox(1)]), "http_sse", :terminal_predecessor)
  end

  test "a tool continuation's grown resend is named by its own claim", %{fixture: fixture} do
    call = %{"type" => "function_call", "call_id" => "call_1", "name" => "shell", "arguments" => "{}"}
    continuation = append(fixture.payload, [call, %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}])
    assert NativeTurnContinuation.turn_role(continuation) == :tool_continuation
    grown = append(continuation, [commentary("first"), mailbox(1)])
    assert NativeTurnContinuation.turn_role(grown) == :tool_continuation
    refute WebsocketTurnIdentity.request_claim_key(fixture.semantic, continuation) == WebsocketTurnIdentity.request_claim_key(fixture.semantic, grown)
    assert NativeMailboxContinuation.attach(witness(fixture, continuation, "websocket"), fixture.semantic, grown, RequestOptions.build(%{}, @endpoint, %{})).mailbox == []
  end

  defp admit!(fixture, payload, "websocket") do
    opts = options(fixture, payload, "websocket")
    assert {:ok, %{request: claim}} = Accounting.claim_websocket_turn(fixture.setup.auth, fixture.setup.model, opts)
    assert {:ok, %{request: request}} = Accounting.reserve(fixture.setup.auth, fixture.setup.model, payload, Map.put(opts, :turn_claim, claim))
    request
  end

  defp admit!(fixture, payload, "http_sse") do
    assert {:ok, %{request: request}} = Accounting.reserve(fixture.setup.auth, fixture.setup.model, payload, options(fixture, payload, "http_sse"))
    request
  end

  defp options(fixture, payload, transport) do
    metadata = if transport == "http_sse", do: %{"native_http_claim_arm" => "opening", "native_http_input_count" => length(payload["input"])}, else: %{}

    %{
      endpoint: @endpoint,
      transport: transport,
      correlation_id: fixture.claim,
      codex_session: fixture.session,
      requested_model: fixture.setup.model.exposed_model_id,
      native_client_retry_witness: witness(fixture, payload, transport),
      native_http_input_count: length(payload["input"]),
      native_http_semantic_turn_key: fixture.semantic,
      request_metadata: metadata,
      reservation_estimate: %{input_tokens: 10, output_tokens: 10}
    }
  end

  # A native HTTP opener is witnessed by the websocket frame it mirrors.
  defp witness(fixture, payload, _transport) do
    {:ok, digest} = WebsocketTurnIdentity.replay_claim_digest(fixture.semantic, Map.put(payload, "type", "response.create"))

    ClientRetry.original_witness!(digest, fixture.setup.api_key.runtime_revocation_epoch)
    |> NativeMailboxContinuation.attach(fixture.semantic, payload, RequestOptions.build(%{}, @endpoint, %{}))
  end

  defp cut!(fixture, request, output, opts \\ []) do
    now = db_now()
    {:ok, digest} = WebsocketTurnIdentity.completed_item_digest(output)
    receipt = %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 1, "completed_item_digests" => [digest]}

    progress =
      progress(output)
      |> Map.put("item_digests", [digest])
      |> then(&if(Keyword.get(opts, :open_tool_call), do: Map.put(&1, "open_tool_call", true), else: &1))

    metadata = if Keyword.get(opts, :progress, true), do: %{"downstream_delivery" => receipt, "native_http_resume_progress" => progress}, else: %{"downstream_delivery" => receipt}
    assert {:ok, attempt} = Accounting.create_attempt(request, fixture.setup.assignment, %{transport: request.transport})
    assert {:ok, _finalized} = Accounting.finalize_failure(request, attempt, %{last_error_code: "client_disconnected", response_status_code: 499, usage: %{status: "usage_unknown", source: "client_disconnected"}, attempt_metadata: metadata})
    sequence = Repo.one(from turn in CodexTurn, where: turn.codex_session_id == ^fixture.session.id, select: coalesce(max(turn.turn_sequence), 0)) + 1

    Repo.insert!(%CodexTurn{
      codex_session_id: fixture.session.id,
      request_id: request.id,
      turn_sequence: sequence,
      transport_kind: request.transport,
      semantic_turn_digest: fixture.semantic,
      status: "interrupted",
      error_code: "client_disconnected",
      final_attempt_id: attempt.id,
      first_visible_output_at: now,
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp progress(output), do: ClientRetry.new_native_http_progress() |> ClientRetry.observe_native_http_output_item(output) |> ClientRetry.native_http_progress_metadata()

  defp assert_refused!(fixture, payload, transport, disposition), do: assert_refused_opts!(fixture, payload, options(fixture, payload, transport), transport, disposition)

  defp assert_refused_opts!(fixture, _payload, opts, "websocket", disposition) do
    before = counts(fixture)
    assert {:error, %{code: :duplicate_request, resend_disposition: ^disposition}} = Accounting.claim_websocket_turn(fixture.setup.auth, fixture.setup.model, opts)
    assert counts(fixture) == before
  end

  defp assert_refused_opts!(fixture, payload, opts, "http_sse", disposition) do
    before = counts(fixture)
    assert {:error, %{code: :duplicate_request, resend_disposition: ^disposition}} = Accounting.reserve(fixture.setup.auth, fixture.setup.model, payload, opts)
    assert counts(fixture) == before
  end

  defp assert_edge!(predecessor, successor) do
    assert {:ok, successor.correlation_id} == ClientRetry.deterministic_failed_predecessor_claim(predecessor.correlation_id, predecessor.id)
    assert successor.request_metadata["client_resend"]["predecessor_request_id"] == predecessor.id
    assert Repo.exists?(from link in RequestClientRetryLink, where: link.predecessor_request_id == ^predecessor.id and link.successor_request_id == ^successor.id)
  end

  defp counts(fixture) do
    requests = from request in Request, where: request.pool_id == ^fixture.setup.pool.id, select: request.id

    %{
      requests: Repo.aggregate(requests, :count),
      attempts: Repo.aggregate(from(a in Attempt, where: a.request_id in subquery(requests)), :count),
      turns: Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^fixture.session.id), :count),
      links: Repo.aggregate(from(l in RequestClientRetryLink, where: l.predecessor_request_id in subquery(requests)), :count),
      settlements: Repo.aggregate(from(l in LedgerEntry, where: l.request_id in subquery(requests) and l.entry_kind == "settlement"), :count)
    }
  end

  defp make_live!(request, :request), do: Repo.update_all(from(r in Request, where: r.id == ^request.id), set: [status: "in_progress", completed_at: nil])
  defp make_live!(request, :attempt), do: Repo.update_all(from(a in Attempt, where: a.request_id == ^request.id), set: [status: "in_progress", completed_at: nil])
  defp make_live!(request, :turn), do: Repo.update_all(from(t in CodexTurn, where: t.request_id == ^request.id), set: [status: "in_progress", completed_at: nil])

  defp expire!(request) do
    expired = DateTime.add(db_now(), -31, :second)
    Repo.update_all(from(r in Request, where: r.id == ^request.id), set: [completed_at: expired])
    Repo.update_all(from(a in Attempt, where: a.request_id == ^request.id), set: [completed_at: expired])
    Repo.update_all(from(t in CodexTurn, where: t.request_id == ^request.id), set: [completed_at: expired])
  end

  defp insert_session!(setup) do
    now = db_now()
    Repo.insert!(%CodexSession{pool_id: setup.pool.id, api_key_id: setup.api_key.id, session_key: "mailbox-turn-#{System.unique_integer([:positive, :monotonic])}", pool_upstream_assignment_id: setup.assignment.id, status: "active", created_at: now, updated_at: now})
  end

  defp payload(model), do: %{"type" => "response.create", "model" => model, "stream" => true, "input" => [%{"type" => "message", "role" => "user", "content" => "synthetic"}], "client_metadata" => %{"x-codex-turn-metadata" => %{"turn_id" => "synthetic-turn", "request_kind" => "turn", "agent_name" => "/root"}}}
  defp append(payload, items), do: Map.update!(payload, "input", &(&1 ++ items))
  defp reasoning(id), do: %{"type" => "reasoning", "id" => "rs_" <> id, "summary" => [], "encrypted_content" => "synthetic-reasoning-" <> id}
  defp commentary(id), do: %{"type" => "message", "id" => "msg_" <> id, "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "synthetic commentary " <> id}]}
  defp mailbox(id), do: %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic update #{id}"}]}

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    DateTime.truncate(now, :microsecond)
  end
end
