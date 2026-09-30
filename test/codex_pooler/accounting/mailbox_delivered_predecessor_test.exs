defmodule CodexPooler.Accounting.MailboxDeliveredPredecessorTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.Gateway.Payloads.{NativeMailboxContinuation, NativeTurnContinuation, RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  # A sub-agent's resume after compaction streams a reasoning item while mail
  # addressed to it is pending. The released client (Codex 0.158) stops reading
  # at that item and sends its next request, with the item and the mail
  # appended, on a new connection, while the connection it left stays open: the
  # Pooler pushes the rest of the response there and settles the resume as
  # delivered. Every resend then met a served predecessor and was refused
  # `409 duplicate_turn` (`terminal_predecessor`) over websocket and over the
  # HTTP fallback, and the sub-agent's turn failed.
  setup do
    setup = accounting_setup()
    session = insert_session!(setup)
    semantic = :crypto.strong_rand_bytes(32)
    payload = payload(setup.model.exposed_model_id)
    {:post_compaction_resume, anchor} = NativeTurnContinuation.turn_role(payload)
    claim = WebsocketTurnIdentity.resume_claim_key(semantic, anchor)
    %{fixture: %{setup: setup, session: session, semantic: semantic, claim: claim, payload: payload}}
  end

  for successor_transport <- ["websocket", "http_sse"] do
    test "a resume left for mail and delivered in full on the old connection admits one #{successor_transport} continuation", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, "websocket")
      handled = reasoning("first")
      deliver!(fixture, original, [handled, commentary("second"), reasoning("third")])

      candidate = append(fixture.payload, [handled, mailbox(1)])
      successor = admit!(fixture, candidate, unquote(successor_transport))
      assert_edge!(original, successor)
      assert counts(fixture) == %{requests: 2, attempts: 1, turns: 1, links: 1, settlements: 1}

      assert_refused!(fixture, candidate, :active_predecessor)
    end
  end

  test "the whole delivered response followed by mail is a continuation too", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    output = [reasoning("first"), commentary("second")]
    deliver!(fixture, original, output)

    successor = admit!(fixture, append(fixture.payload, output ++ [mailbox(1)]), "websocket")
    assert_edge!(original, successor)
  end

  test "a delivered resume keeps the fence for every resend the mail does not explain", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    first = reasoning("first")
    second = commentary("second")
    deliver!(fixture, original, [first, second])

    assert_http_refused!(fixture, fixture.payload, :terminal_predecessor)
    assert_refused!(fixture, append(fixture.payload, [first]), :terminal_predecessor)
    assert_refused!(fixture, append(fixture.payload, [reasoning("changed"), mailbox(1)]), :terminal_predecessor)
    assert_refused!(fixture, append(fixture.payload, [second, mailbox(1)]), :terminal_predecessor)
    assert_refused!(fixture, append(fixture.payload, [first, second, reasoning("extra"), mailbox(1)]), :terminal_predecessor)
    assert_http_refused!(fixture, append(fixture.payload, [reasoning("changed"), mailbox(1)]), :terminal_predecessor)
  end

  # An identical websocket resend inside the retry window is served as the
  # delivered resume's successor, like any identical resend after an unread
  # response; over HTTP it still meets the websocket predecessor (above).
  test "a byte-identical websocket resend of a delivered resume is chained", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    deliver!(fixture, original, [reasoning("first"), commentary("second")])
    successor = admit!(fixture, fixture.payload, "websocket")
    assert_edge!(original, successor)
    assert counts(fixture) == %{requests: 2, attempts: 1, turns: 1, links: 1, settlements: 1}
  end

  test "a receipt that does not name every delivered item keeps the fence", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    first = reasoning("first")
    deliver!(fixture, original, [first, commentary("second")], completed_items: 3)
    assert_refused!(fixture, append(fixture.payload, [first, mailbox(1)]), :terminal_predecessor)
  end

  test "an aborted delivery is not read as a served one", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    first = reasoning("first")
    deliver!(fixture, original, [first, commentary("second")], outcome: "aborted")
    assert_refused!(fixture, append(fixture.payload, [first, mailbox(1)]), :terminal_predecessor)
  end

  # A served request still in flight is live; a served request whose attempt or
  # turn is not served names no delivered response the mail can explain.
  for {live_row, disposition} <- [request: :active_predecessor, attempt: :terminal_predecessor, turn: :terminal_predecessor] do
    test "a live delivered #{live_row} keeps the duplicate fence", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, "websocket")
      first = reasoning("first")
      deliver!(fixture, original, [first, commentary("second")])
      make_live!(original, unquote(live_row))
      assert_refused!(fixture, append(fixture.payload, [first, mailbox(1)]), unquote(disposition))
    end
  end

  test "a delivered resume past the retry window keeps the fence", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    first = reasoning("first")
    deliver!(fixture, original, [first, commentary("second")])
    expire!(original)
    assert_refused!(fixture, append(fixture.payload, [first, mailbox(1)]), :retry_expired)
  end

  test "a delivered resume admits one continuation, not a second one", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "websocket")
    first = reasoning("first")
    deliver!(fixture, original, [first, commentary("second")])
    foreign_fixture = %{fixture | claim: "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
    foreign = admit!(foreign_fixture, fixture.payload, "websocket")
    ClientRetry.insert_link!(original, foreign, db_now())
    assert_refused!(fixture, append(fixture.payload, [first, mailbox(1)]), :terminal_predecessor)
  end

  # The provider pushes a reasoning item with `"content": []`; the client keeps
  # the field only when it holds reasoning text and resends the item without
  # it. The receipt's item identity used to keep the empty list, so the resend
  # never named the delivered item and a resume cut for mail was refused.
  for {predecessor_transport, successor_transport} <- [{"websocket", "websocket"}, {"http_sse", "http_sse"}, {"websocket", "http_sse"}] do
    test "a #{predecessor_transport} resume cut after a reasoning item without reasoning text admits the #{successor_transport} mail continuation", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(predecessor_transport))
      pushed = Map.put(reasoning("first"), "content", [])
      cut!(fixture, original, pushed)

      successor = admit!(fixture, append(fixture.payload, [reasoning("first"), mailbox(1)]), unquote(successor_transport))
      assert_edge!(original, successor)
    end
  end

  # The released client stopped at the reasoning item while the stream went on
  # to open a call; it never saw that call complete, so it never ran it.
  test "an HTTP resume cut after reasoning with a call still open admits the mail continuation once", %{fixture: fixture} do
    original = admit!(fixture, fixture.payload, "http_sse")
    cut!(fixture, original, Map.put(reasoning("first"), "content", []), open_tool_call: true)
    candidate = append(fixture.payload, [reasoning("first"), mailbox(1)])
    assert_http_refused!(fixture, append(fixture.payload, [reasoning("changed"), mailbox(1)]), :terminal_predecessor)
    successor = admit!(fixture, candidate, "http_sse")
    assert_edge!(original, successor)
    assert_http_refused!(fixture, candidate, :active_predecessor)
    assert counts(fixture) == %{requests: 2, attempts: 1, turns: 1, links: 1, settlements: 1}
  end

  # The provider may add fields to a pushed reasoning item or to its summary
  # parts that the client's closed reasoning model drops: the resend of a
  # delivered reasoning item then carried none of them. Binding them left every
  # resend of a resume cut for mail from a peer refused `terminal_predecessor`.
  for {predecessor_transport, successor_transport} <- [{"http_sse", "http_sse"}, {"websocket", "websocket"}, {"websocket", "http_sse"}] do
    test "a #{predecessor_transport} resume cut after a reasoning item with provider-only fields admits the #{successor_transport} peer mail continuation once", %{fixture: fixture} do
      original = admit!(fixture, fixture.payload, unquote(predecessor_transport))
      cut!(fixture, original, provider_reasoning("first"), open_tool_call: unquote(predecessor_transport) == "http_sse")

      client = client_reasoning("first")
      candidate = append(fixture.payload, [client, peer_mailbox(1)])
      assert_refused!(fixture, append(fixture.payload, [Map.put(client, "encrypted_content", "synthetic-changed"), peer_mailbox(1)]), :terminal_predecessor)
      assert_http_refused!(fixture, append(fixture.payload, [Map.put(client, "id", "rs_changed"), peer_mailbox(1)]), :terminal_predecessor)

      successor = admit!(fixture, candidate, unquote(successor_transport))
      assert_edge!(original, successor)
      assert_http_refused!(fixture, candidate, :active_predecessor)
      assert_refused!(fixture, candidate, :active_predecessor)
      assert counts(fixture) == %{requests: 2, attempts: 1, turns: 1, links: 1, settlements: 1}
    end
  end

  test "a reasoning item's identity binds only the fields the client resends" do
    {:ok, client} = WebsocketTurnIdentity.completed_item_digest(client_reasoning("first"))
    assert {:ok, ^client} = WebsocketTurnIdentity.completed_item_digest(provider_reasoning("first"))

    for changed <- [%{"id" => "rs_changed"}, %{"encrypted_content" => "synthetic-changed"}, %{"summary" => [%{"type" => "summary_text", "text" => "changed"}]}] do
      refute {:ok, client} == WebsocketTurnIdentity.completed_item_digest(Map.merge(client_reasoning("first"), changed))
    end

    {:ok, with_text} = WebsocketTurnIdentity.completed_item_digest(Map.put(client_reasoning("first"), "content", [%{"type" => "reasoning_text", "text" => "synthetic"}]))
    assert {:ok, ^with_text} = WebsocketTurnIdentity.completed_item_digest(Map.put(provider_reasoning("first"), "content", [%{"type" => "reasoning_text", "text" => "synthetic", "provider_part_field" => 1}]))

    message = Map.put(commentary("first"), "provider_field", "synthetic")
    refute WebsocketTurnIdentity.completed_item_digest(message) == WebsocketTurnIdentity.completed_item_digest(commentary("first"))
  end

  test "reasoning text stays bound in a completed item's identity" do
    item = reasoning("first")
    {:ok, bare} = WebsocketTurnIdentity.completed_item_digest(item)

    assert {:ok, ^bare} = WebsocketTurnIdentity.completed_item_digest(Map.put(item, "content", []))
    assert {:ok, ^bare} = WebsocketTurnIdentity.completed_item_digest(Map.put(item, "content", nil))
    assert {:ok, ^bare} = WebsocketTurnIdentity.completed_item_digest(Map.put(item, "content", [%{"type" => "text", "text" => "synthetic"}]))

    {:ok, with_text} = WebsocketTurnIdentity.completed_item_digest(Map.put(item, "content", [%{"type" => "reasoning_text", "text" => "synthetic"}]))
    refute with_text == bare

    message = %{"type" => "message", "role" => "assistant", "content" => []}
    {:ok, empty_message} = WebsocketTurnIdentity.completed_item_digest(message)
    refute {:ok, empty_message} == WebsocketTurnIdentity.completed_item_digest(Map.delete(message, "content"))
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
    metadata = if transport == "http_sse", do: %{"native_http_claim_arm" => "post_compaction_resume", "native_http_input_count" => length(payload["input"])}, else: %{}

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

  defp witness(fixture, payload, transport) do
    {:ok, digest} =
      case transport do
        "websocket" -> WebsocketTurnIdentity.replay_claim_digest(fixture.semantic, payload)
        "http_sse" -> WebsocketTurnIdentity.http_resume_input_digest(fixture.semantic, payload["input"])
      end

    ClientRetry.original_witness!(digest, fixture.setup.api_key.runtime_revocation_epoch)
    |> NativeMailboxContinuation.attach(fixture.semantic, payload, RequestOptions.build(%{}, @endpoint, %{}))
  end

  # The response went out in full on the connection the client left.
  defp deliver!(fixture, request, outputs, overrides \\ []) do
    digests = Enum.map(outputs, &item_digest/1)

    receipt = %{
      "outcome" => Keyword.get(overrides, :outcome, "delivered"),
      "transport" => "websocket",
      "terminal_class" => "response.completed",
      "highest_frame_class" => "terminal",
      "frames_after_visible" => 12,
      "completed_items" => Keyword.get(overrides, :completed_items, length(outputs)),
      "completed_item_digests" => digests
    }

    assert {:ok, attempt} = Accounting.create_attempt(request, fixture.setup.assignment, %{transport: request.transport})
    assert {:ok, _finalized} = Accounting.finalize_success(request, attempt, %{status: "usage_known", input_tokens: 4, output_tokens: 4, total_tokens: 8}, %{attempt_metadata: %{"downstream_delivery" => receipt}})
    insert_turn!(fixture, request, attempt, "succeeded", nil)
  end

  defp cut!(fixture, request, output, opts \\ []) do
    digest = item_digest(output)
    receipt = %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 1, "completed_item_digests" => [digest]}
    progress = ClientRetry.new_native_http_progress() |> ClientRetry.observe_native_http_output_item(output) |> ClientRetry.native_http_progress_metadata() |> Map.put("item_digests", [digest])
    progress = if Keyword.get(opts, :open_tool_call), do: Map.put(progress, "open_tool_call", true), else: progress
    assert {:ok, attempt} = Accounting.create_attempt(request, fixture.setup.assignment, %{transport: request.transport})
    assert {:ok, _finalized} = Accounting.finalize_failure(request, attempt, %{last_error_code: "client_disconnected", response_status_code: 499, usage: %{status: "usage_unknown", source: "client_disconnected"}, attempt_metadata: %{"downstream_delivery" => receipt, "native_http_resume_progress" => progress}})
    insert_turn!(fixture, request, attempt, "interrupted", "client_disconnected")
  end

  defp insert_turn!(fixture, request, attempt, status, error_code) do
    now = db_now()
    sequence = Repo.one(from turn in CodexTurn, where: turn.codex_session_id == ^fixture.session.id, select: coalesce(max(turn.turn_sequence), 0)) + 1

    Repo.insert!(%CodexTurn{
      codex_session_id: fixture.session.id,
      request_id: request.id,
      turn_sequence: sequence,
      transport_kind: request.transport,
      semantic_turn_digest: fixture.semantic,
      status: status,
      error_code: error_code,
      final_attempt_id: attempt.id,
      first_visible_output_at: now,
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp item_digest(item) do
    {:ok, digest} = WebsocketTurnIdentity.completed_item_digest(item)
    digest
  end

  defp assert_refused!(fixture, payload, disposition) do
    before = counts(fixture)
    assert {:error, %{code: :duplicate_request, resend_disposition: ^disposition}} = Accounting.claim_websocket_turn(fixture.setup.auth, fixture.setup.model, options(fixture, payload, "websocket"))
    assert counts(fixture) == before
  end

  defp assert_http_refused!(fixture, payload, disposition) do
    before = counts(fixture)
    assert {:error, %{code: :duplicate_request, resend_disposition: ^disposition}} = Accounting.reserve(fixture.setup.auth, fixture.setup.model, payload, options(fixture, payload, "http_sse"))
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
    Repo.insert!(%CodexSession{pool_id: setup.pool.id, api_key_id: setup.api_key.id, session_key: "mailbox-delivered-#{System.unique_integer([:positive, :monotonic])}", pool_upstream_assignment_id: setup.assignment.id, status: "active", created_at: now, updated_at: now})
  end

  defp payload(model), do: %{"type" => "response.create", "model" => model, "stream" => true, "input" => [%{"type" => "message", "role" => "user", "content" => "synthetic"}, %{"type" => "compaction", "encrypted_content" => "synthetic-pivot"}], "client_metadata" => %{"x-codex-turn-metadata" => %{"turn_id" => "synthetic-turn", "request_kind" => "turn", "agent_name" => "/root/worker"}}}
  defp append(payload, items), do: Map.update!(payload, "input", &(&1 ++ items))
  defp reasoning(id), do: %{"type" => "reasoning", "id" => "rs_" <> id, "summary" => [], "encrypted_content" => "synthetic-reasoning-" <> id}
  defp commentary(id), do: %{"type" => "message", "role" => "assistant", "phase" => "commentary", "id" => "msg_" <> id, "content" => [%{"type" => "output_text", "text" => "synthetic note " <> id}]}
  defp client_reasoning(id), do: %{reasoning(id) | "summary" => [%{"type" => "summary_text", "text" => "synthetic summary " <> id}]}

  defp provider_reasoning(id) do
    client_reasoning(id)
    |> Map.merge(%{"status" => "completed", "content" => [], "provider_field" => "synthetic"})
    |> Map.update!("summary", fn parts -> Enum.map(parts, &Map.put(&1, "provider_part_field", "synthetic")) end)
  end

  defp peer_mailbox(id), do: %{mailbox(id) | "author" => "/root/worker_b"}

  defp mailbox(id), do: %{"type" => "agent_message", "author" => "/root", "recipient" => "/root/worker", "content" => [%{"type" => "input_text", "text" => "synthetic update #{id}"}]}

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    DateTime.truncate(now, :microsecond)
  end
end
