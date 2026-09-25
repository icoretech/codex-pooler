defmodule CodexPoolerWeb.Runtime.BackendCodexHttpDuplicateTurnTest do
  # The duplicate-turn fence was structurally websocket-only
  # (icoretech/codex-pooler-findings#212). A native Codex turn sent over
  # `POST /backend-api/codex/responses` reserved under a freshly generated
  # UUID, so a resend of the same turn never met `requests_correlation_id_uq`,
  # never reached the resend policy, and bought a second upstream dispatch --
  # while the same resend over a websocket was refused `409 duplicate_turn`.
  #
  # Every assertion here is taken from the real HTTP surface: the identity
  # comes from the inbound `x-codex-turn-metadata` header the released client
  # already sends, the refusal is the public status and body, and the proof of
  # "no duplicated provider work" is the fake upstream's own request count,
  # not a fixture the test wrote.
  #
  # The released client sends the canonical document BOTH in the request body's
  # `client_metadata` (`codex-rs/core/src/client.rs:893`) and as a bounded
  # header copy, and the two carriers must classify identically. A suite that
  # drove only one of them read as evidence for a path that was broken on the
  # other (findings#212, row 212-49), so the core fence behaviours here are
  # parameterised over both carriers through `post_turn/5`'s `:where` option.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, RoutingCircuitState}
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @turn_id "turn_212_native_http"
  @session_header "session-id"
  @metadata_header "x-codex-turn-metadata"

  defmodule ClosingAdapter do
    @moduledoc false

    def chunk(%{closed?: true}, _data), do: {:error, :closed}

    def chunk(%{adapter: adapter, payload: payload} = state, data) do
      {:ok, body, payload} = adapter.chunk(payload, data)
      closed? = body == state.close_after
      {:ok, body, %{state | payload: payload, closed?: closed?}}
    end
  end

  for carrier <- [:header, :body] do
    test "an identical native HTTP resend is refused and buys no second upstream dispatch (#{carrier})",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_duplicate_turn"}))
      setup = gateway_setup(upstream)
      session = session_id()

      first = post_turn(conn, setup, session, @turn_id, where: unquote(carrier))
      assert %{"id" => "resp_duplicate_turn"} = json_response(first, 200)
      assert FakeUpstream.count(upstream) == 1

      second = post_turn(conn, setup, session, @turn_id, where: unquote(carrier))

      assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(second, 409)

      # The whole point of the row: the provider is not paid a second time, and
      # nothing was reserved, attempted or recorded for the refused resend.
      assert FakeUpstream.count(upstream) == 1
      assert [request] = pool_requests(setup)
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1

      # A turn's opening request is named by the turn alone, exactly as the
      # websocket path names it, so the claim survives a rebuilt retry body.
      assert String.starts_with?(request.correlation_id, "codex-turn:")
    end
  end

  # After a remote compaction the released client advances its window
  # (`compact_remote_v2.rs:323`), and `x-codex-window-id` is minted as
  # `"{thread_id}:{window_number}"` (`session/mod.rs:4449-4459`). The resend of
  # the very turn that compacted therefore carries a NEW window while the
  # `session-id`, the thread, the `turn_id` and the authorized history are
  # unchanged -- the certified wire capture of the post-compaction lane shows
  # exactly that (`windowOrdinal` 1 -> 2, one `sessionOrdinal`, one `turnId`,
  # `inputEqual: true`). The session key prefers the window since `6441e83d`, so
  # the resend opened a SECOND codex session and a claim named after the session
  # UUID could not meet its own predecessor: the fence stayed green while the
  # provider was asked the same history twice
  # (icoretech/codex-pooler-findings#250).
  test "an identical resend of the first post-compaction turn is fenced across a window rotation",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_window_rotation"}))
    setup = gateway_setup(upstream)
    session = session_id()
    thread = thread_id()

    opening = post_window_turn(conn, setup, session, thread, 1, @turn_id)
    assert %{"id" => "resp_window_rotation"} = json_response(opening, 200)
    assert FakeUpstream.count(upstream) == 1

    resend = post_window_turn(conn, setup, session, thread, 2, @turn_id)
    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(resend, 409)

    # The provider is not paid a second time and the refused resend records
    # nothing, exactly as a resend inside one window already did.
    assert FakeUpstream.count(upstream) == 1
    assert [opening_request] = pool_requests(setup)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^opening_request.id), :count) == 1

    # A genuinely new turn of the rotated window is still ordinary work.
    successor_turn_id = @turn_id <> "_successor"
    successor = post_window_turn(conn, setup, session, thread, 2, successor_turn_id)
    assert %{"id" => "resp_window_rotation"} = json_response(successor, 200)
    assert FakeUpstream.count(upstream) == 2

    # And it is still filed under its own window-keyed session: the claim now
    # follows the thread, while routing and affinity keep following the window
    # exactly where `6441e83d` put them.
    assert [^opening_request, successor_request] = pool_requests(setup)

    assert opening_request.request_metadata["codex_session_key"] ==
             window_session_key(thread, 1)

    assert successor_request.request_metadata["codex_session_key"] ==
             window_session_key(thread, 2)

    refute opening_request.request_metadata["codex_session_id"] ==
             successor_request.request_metadata["codex_session_id"]
  end

  # `409 duplicate_turn` is a public response on a runtime route, so the
  # machine-readable route/feature contract has to carry it for both transports
  # and has to be answerable from the route itself rather than from prose
  # (findings#212). The two grown-body gaps the entry records are proven
  # behaviorally by the known-gap test below.
  test "the compatibility matrix duplicate-turn entry is the refusal this route produces", %{
    conn: conn
  } do
    feature = CompatibilityMatrix.by_slug!(:duplicate_turn_fence)
    fixture = CompatibilityMatrix.fixture!(:duplicate_turn_fence)

    assert %{method: :post, path: "/backend-api/codex/responses"} in feature.routes

    assert %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"} in feature.routes

    assert "websocket" in feature.duplicate_turn.public_error.transports
    assert "http_sse" in feature.duplicate_turn.public_error.transports

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_matrix_turn"}))
    setup = gateway_setup(upstream)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id), 200)

    %{status: status, code: code} = feature.duplicate_turn.public_error

    assert %{"error" => %{"code" => ^code}} =
             json_response(post_turn(conn, setup, session, @turn_id), status)

    assert [request] = pool_requests(setup)
    assert String.starts_with?(request.correlation_id, fixture.claim_prefixes.turn)
    assert FakeUpstream.count(upstream) == 1
  end

  # The entry's machine-readable fields were prose the suite ran past: a nonsense
  # claim-shape string and an inverted `known_gaps` value both left the contract
  # suites green (findings#212, 212-33). This test now compares every value it
  # names against an outcome it drove, so a stale executable entry fails. The
  # matrix classifies the remaining descriptive fields outside that executable
  # subset, and this test asserts that classification exhaustively.
  #
  # The table is the test's own, not the matrix's; asserting the matrix against
  # itself is what made the previous version self-referential.
  @claim_shape_by_prefix %{
    "codex-turn:" => "bare_payload_independent_codex_turn_claim",
    "codex-request:" => "payload_scoped_request_claim",
    "codex-resume:" => "compaction_anchored_resume_claim",
    "codex-kind:" => "kind_scoped_request_claim"
  }
  @public_error %{status: 409, code: "duplicate_turn"}
  @public_error_transports ["http_json", "http_sse", "websocket"]

  test "the compatibility matrix executable split names every route-driven value" do
    contract = CompatibilityMatrix.by_slug!(:duplicate_turn_fence).duplicate_turn

    assert contract.executable_fields == [
             :advanced_http_resume,
             :claim_by_request_kind,
             :known_gaps,
             :partial_http_tool_retry,
             :payload_independent_claims,
             :public_error
           ]

    assert contract.documentary_fields == [
             :bare_claim_request_kinds,
             :continuation_discriminator,
             :diagnostics,
             :disposition_scope,
             :metadata_sources,
             :refusal_dispositions,
             :unfenced
           ]

    assert contract
           |> Map.keys()
           |> Enum.reject(&(&1 in [:executable_fields, :documentary_fields]))
           |> Enum.sort() == Enum.sort(contract.executable_fields ++ contract.documentary_fields)
  end

  test "the compatibility matrix pins the delivered-output resume successor" do
    contract = CompatibilityMatrix.by_slug!(:duplicate_turn_fence).duplicate_turn

    assert contract.advanced_http_resume == %{
             predecessor_transport: "http_sse",
             predecessor_error: "client_disconnected",
             predecessor_claim_arm: "post_compaction_resume",
             successor_prefix: "codex-request-retry:",
             requires_input_prefix_match: true,
             requires_delivered_output_receipt_match: true,
             identical_retry_refused: true
           }
  end

  test "the compatibility matrix claim shapes are the ones this route produces", %{conn: conn} do
    contract = CompatibilityMatrix.by_slug!(:duplicate_turn_fence).duplicate_turn
    shapes = contract.claim_by_request_kind

    assert Map.take(contract.public_error, [:status, :code]) == @public_error
    assert Enum.sort(contract.public_error.transports) == Enum.sort(@public_error_transports)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_shape_turn"}),
          FakeUpstream.json_response(%{"id" => "resp_shape_continuation"}),
          FakeUpstream.json_response(%{"id" => "resp_shape_resume"}),
          FakeUpstream.json_response(%{"id" => "resp_shape_compaction"}),
          FakeUpstream.json_response(%{"id" => "resp_shape_prewarm"}),
          FakeUpstream.json_response(%{"id" => "resp_shape_kind"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    # One request per claim shape the entry names, each under its own turn id so
    # they cannot fence one another.
    driven = [
      {:turn, post_turn(conn, setup, session, "shape_turn", where: :body)},
      {:tool_result_continuation, post_turn(conn, setup, session, "shape_tool", where: :body, input: tool_round())},
      {:post_compaction_resume, post_turn(conn, setup, session, "shape_resume", where: :body, input: compacted_history())},
      {:compaction,
       post_turn(conn, setup, session, "shape_compaction",
         where: :body,
         document: kind_metadata("compaction"),
         input: native_text_input("h") ++ [%{"type" => "compaction_trigger"}]
       )},
      {:prewarm, post_turn(conn, setup, session, "shape_prewarm", document: kind_metadata("prewarm", "shape_prewarm"))},
      {:memory, post_turn(conn, setup, session, "shape_memory", document: kind_metadata("memory", "shape_memory"))}
    ]

    for {_kind, conn} <- driven, do: assert(json_response(conn, 200))

    rows = pool_requests(setup)
    assert length(rows) == length(driven)

    # Every entry's shape AND prefix has to match the row the route produced.
    for {{kind, _conn}, request} <- Enum.zip(driven, rows) do
      entry = Map.fetch!(shapes, kind)
      assert String.starts_with?(request.correlation_id, entry.prefix)
      assert entry.shape == Map.fetch!(@claim_shape_by_prefix, entry.prefix)
    end

    assert Map.fetch!(shapes, :prewarm) == Map.fetch!(shapes, :memory)
  end

  # The recorded gaps are outcomes, not prose: each one is driven and the entry's
  # boolean has to equal what the route did.
  test "the compatibility matrix known gaps are the outcomes this route produces", %{conn: conn} do
    feature = CompatibilityMatrix.by_slug!(:duplicate_turn_fence).duplicate_turn
    gaps = feature.known_gaps

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_gap_one"}),
          FakeUpstream.json_response(%{"id" => "resp_gap_two"}),
          FakeUpstream.json_response(%{"id" => "resp_compaction_gap_one"}),
          FakeUpstream.json_response(%{"id" => "resp_compaction_gap_two"})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    assert json_response(
             post_turn(conn, setup, session, @turn_id, where: :body, input: tool_round()),
             200
           )

    grown = tool_round() ++ [trailing_item(:assistant)]
    second = post_turn(conn, setup, session, @turn_id, where: :body, input: grown)

    assert gaps.tool_result_continuation_grown_body_retry_fenced == (second.status == 409)
    refute gaps.tool_result_continuation_grown_body_retry_fenced

    compaction = fn text ->
      post_turn(conn, setup, session, "matrix_compaction_gap",
        where: :body,
        document: kind_metadata("compaction", "matrix_compaction_gap"),
        input: native_text_input(text) ++ [%{"type" => "compaction_trigger"}]
      )
    end

    assert json_response(compaction.("history as it stood"), 200)
    changed_compaction = compaction.("history as it stood, plus one more item")

    assert gaps.compaction_changed_body_retry_fenced == (changed_compaction.status == 409)
    refute gaps.compaction_changed_body_retry_fenced

    # The claims the entry calls payload-independent are the two that carry no
    # `known_gaps` entry, and neither names a payload-scoped domain.
    assert feature.payload_independent_claims == [:turn, :post_compaction_resume]

    for kind <- feature.payload_independent_claims do
      refute Map.has_key?(gaps, :"#{kind}_grown_body_retry_fenced")
    end
  end

  # The cohort in the row is streaming: a native Codex turn resolves to
  # `http_sse`, which is exactly the transport that got a fresh UUID and a
  # second dispatch. The refusal lands before any upstream work, so the resend
  # is answered with the pre-dispatch JSON error rather than an event stream.
  test "a streaming native HTTP turn is fenced on the http_sse transport", %{conn: conn} do
    upstream = start_upstream(stream_success_sse())
    setup = gateway_setup(upstream)
    session = session_id()

    first = post_turn(conn, setup, session, @turn_id, stream: true)
    assert response(first, 200)
    assert FakeUpstream.count(upstream) == 1

    second = post_turn(conn, setup, session, @turn_id, stream: true)
    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(second, 409)

    assert FakeUpstream.count(upstream) == 1
    assert [%Request{transport: "http_sse"} = request] = pool_requests(setup)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1
  end

  # The fence must never become a hard failure for ordinary error recovery. It
  # refuses only a resend whose predecessor already delivered provider output
  # for the turn; a predecessor that was refused before producing anything has
  # no spend to protect, so the retry is served exactly as it is today. A
  # first-event `server_error` is that shape: the turn is marked visible because
  # the error event itself is written downstream, but no model output was ever
  # produced.
  for code <- ["server_error", "rate_limit_exceeded"] do
    test "a resend after zero-output provider failure #{code} is served, not refused", %{
      conn: conn
    } do
      code = unquote(code)
      upstream = start_upstream(first_event_terminal_sse("response.failed", code))
      setup = gateway_setup(upstream)
      session = session_id()

      first = post_turn(conn, setup, session, @turn_id, stream: true)
      assert response(first, 200)

      assert [predecessor] = pool_requests(setup)
      assert predecessor.status == "failed"
      assert predecessor.last_error_code == code
      dispatched = FakeUpstream.count(upstream)

      second = post_turn(conn, setup, session, @turn_id, stream: true)
      assert response(second, 200)

      assert FakeUpstream.count(upstream) > dispatched
      assert [^predecessor, successor] = pool_requests(setup)

      # Falling open steps OVER the zero-output predecessor rather than abandoning
      # the turn: the successor is still named by this turn, through the same
      # deterministic derivation the websocket resend chain uses. A fresh UUID
      # here would switch the fence off for this turn permanently.
      assert String.starts_with?(successor.correlation_id, "codex-request-retry:")
    end
  end

  test "a resend after no eligible backend is served once routing recovers", %{conn: conn} do
    upstream = start_upstream(stream_success_sse())
    setup = gateway_setup(upstream)
    session = session_id()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RoutingCircuitState{
      pool_id: setup.pool.id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.identity.id,
      model_identifier: setup.model.exposed_model_id,
      route_class: "proxy_stream",
      status: "open",
      reason_code: "upstream_network_error",
      failure_count: 3,
      success_count: 0,
      opened_at: now,
      next_probe_at: DateTime.add(now, 60, :second),
      metadata: %{"probe_in_flight_count" => 0},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()

    first = post_turn(conn, setup, session, @turn_id, stream: true)
    assert %{"error" => %{"code" => "no_eligible_backend"}} = json_response(first, 503)
    assert [predecessor] = pool_requests(setup)
    assert predecessor.last_error_code == "no_eligible_backend"
    assert FakeUpstream.count(upstream) == 0

    Repo.delete_all(from(c in RoutingCircuitState, where: c.pool_id == ^setup.pool.id))

    second = post_turn(conn, setup, session, @turn_id, stream: true)
    assert response(second, 200)
    assert FakeUpstream.count(upstream) == 1
    assert [^predecessor, successor] = pool_requests(setup)

    # The pre-dispatch denial never reserved the turn claim, so recovery uses
    # the original claim rather than stepping over a claimed predecessor.
    assert String.starts_with?(successor.correlation_id, "codex-turn:")
    refute predecessor.correlation_id == successor.correlation_id
  end

  test "a resend after a relayed 4xx is served, not refused", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(
            %{"error" => %{"type" => "invalid_request_error", "code" => "bad_request"}},
            400
          ),
          stream_success_sse()
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    first = post_turn(conn, setup, session, @turn_id, stream: true)
    assert response(first, 400)
    assert [predecessor] = pool_requests(setup)
    assert predecessor.last_error_code == "upstream_status"
    assert FakeUpstream.count(upstream) == 1

    second = post_turn(conn, setup, session, @turn_id, stream: true)
    assert response(second, 200)
    assert FakeUpstream.count(upstream) == 2
    assert [^predecessor, successor] = pool_requests(setup)
    assert String.starts_with?(successor.correlation_id, "codex-request-retry:")
  end

  test "a post-compaction resume routes a zero-output resend through the native claim chain", %{
    conn: conn
  } do
    upstream = start_upstream(first_event_terminal_sse("response.failed", "server_error"))
    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    resume = fn ->
      post_turn(conn, setup, session, @turn_id,
        where: :body,
        input: compacted_history(),
        stream: true
      )
    end

    assert response(resume.(), 200)
    assert [predecessor] = pool_requests(setup)
    assert String.starts_with?(predecessor.correlation_id, "codex-resume:")

    dispatched = FakeUpstream.count(upstream)
    assert response(resume.(), 200)

    assert FakeUpstream.count(upstream) > dispatched
    assert [^predecessor, successor] = pool_requests(setup)
    assert String.starts_with?(successor.correlation_id, "codex-request-retry:")
  end

  test "a kind-scoped request routes a zero-output resend through the native claim chain", %{
    conn: conn
  } do
    upstream = start_upstream(first_event_terminal_sse("response.failed", "server_error"))
    setup = gateway_setup(upstream)
    session = session_id()
    prefix = compatibility_claim_prefix(:memory)

    memory = fn ->
      post_turn(conn, setup, session, @turn_id,
        document: kind_metadata("memory"),
        stream: true
      )
    end

    assert response(memory.(), 200)
    assert [predecessor] = pool_requests(setup)
    assert String.starts_with?(predecessor.correlation_id, prefix)

    dispatched = FakeUpstream.count(upstream)
    assert response(memory.(), 200)

    assert FakeUpstream.count(upstream) > dispatched
    assert [^predecessor, successor] = pool_requests(setup)
    assert String.starts_with?(successor.correlation_id, "codex-request-retry:")
  end

  # The chain is what makes falling open safe. A turn whose first attempt bought
  # nothing is served; if a LATER attempt of that same turn delivers output and
  # is then resent, the fence must still be there to refuse it. With a fresh
  # UUID on fall-open it would not be.
  test "a turn served past a zero-output failure is still fenced once it delivers output", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          first_event_terminal_sse("response.failed", "server_error"),
          stream_success_sse()
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    # Attempt 1 buys nothing and is served.
    assert response(post_turn(conn, setup, session, @turn_id, stream: true), 200)
    # Attempt 2 is served past it, and this one really does deliver output.
    assert response(post_turn(conn, setup, session, @turn_id, stream: true), 200)

    assert [zero_output, delivered] = pool_requests(setup)
    assert zero_output.last_error_code == "server_error"
    assert delivered.status == "succeeded"
    dispatched = FakeUpstream.count(upstream)

    # Attempt 3 would be the second dispatch of work already delivered.
    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(post_turn(conn, setup, session, @turn_id, stream: true), 409)

    assert FakeUpstream.count(upstream) == dispatched
    assert length(pool_requests(setup)) == 2
  end

  # The chain is bounded, and at the bound it stops DERIVING rather than
  # starting to refuse. Every step of it is a zero-output predecessor, which is
  # the cohort the fence deliberately serves and which the runbook records a 409
  # for as a defect; rolling back at the bound turned a long
  # `rate_limit_exceeded` run into a hard terminal error with no duplicate spend
  # to protect (findings#212, rows 212-50 and 212-45).
  #
  # The routing circuit is cleared between attempts so the chain is the only
  # thing under test: an open circuit would end the run with `no_eligible_backend`
  # long before the depth bound is reached.
  @tag slow: "dispatches and accounts twenty real HTTP turns to cross the durable retry-chain depth bound"
  test "a turn past the chain depth bound is still served, not refused", %{conn: conn} do
    upstream = start_upstream(first_event_terminal_sse("response.failed", "rate_limit_exceeded"))
    setup = gateway_setup(upstream)
    session = session_id()
    pool_id = setup.pool.id

    statuses =
      for _attempt <- 1..20 do
        Repo.delete_all(from(c in RoutingCircuitState, where: c.pool_id == ^pool_id))
        post_turn(conn, setup, session, @turn_id, stream: true).status
      end

    assert Enum.uniq(statuses) == [200]
    assert FakeUpstream.count(upstream) == 20
    assert length(pool_requests(setup)) == 20

    # Past the bound the successor gives up the turn's derived identity rather
    # than the request, so the row exists and carries a generated id.
    past_the_bound = setup |> pool_requests() |> List.last()
    assert {:ok, _uuid} = Ecto.UUID.cast(past_the_bound.correlation_id)
  end

  # A predecessor left live by a killed node keeps `completed_at` null until the
  # `*/15` `runtime_cleanup` cron finalizes it. Refusing every retry in that
  # window would be a terminal error on the default transport with no duplicate
  # spend to prevent, so an unfinished predecessor falls open.
  test "a retry while the predecessor is still unfinished is served", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_live_one"}),
          FakeUpstream.json_response(%{"id" => "resp_live_two"})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id), 200)

    # Strand the predecessor exactly as a killed node leaves it: accepted work,
    # no completion, nothing for `runtime_cleanup` to have swept yet.
    [predecessor] = pool_requests(setup)

    {1, _} =
      Repo.update_all(
        from(r in Request, where: r.id == ^predecessor.id),
        set: [status: "in_progress", completed_at: nil]
      )

    assert json_response(post_turn(conn, setup, session, @turn_id), 200)
    assert FakeUpstream.count(upstream) == 2
    assert length(pool_requests(setup)) == 2
  end

  # The released client sends the canonical turn metadata in the request body's
  # `client_metadata` (`codex-rs/core/src/client.rs:893`); the header is a
  # bounded copy. A client that sends only the body must still be fenced.
  test "the real client body shape is fenced without any turn metadata header", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_body_metadata"}))
    setup = gateway_setup(upstream)
    session = session_id()

    body = %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("real client body shape"),
      "client_metadata" => %{
        "session_id" => "client-session",
        "thread_id" => "client-thread",
        "x-codex-window-id" => "client-window",
        "turn_id" => @turn_id,
        "x-codex-turn-metadata" => turn_metadata(@turn_id)
      }
    }

    post_body = fn ->
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header(@session_header, session)
      |> post("/backend-api/codex/responses", body)
    end

    assert json_response(post_body.(), 200)
    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(post_body.(), 409)

    assert FakeUpstream.count(upstream) == 1
    assert [request] = pool_requests(setup)
    assert String.starts_with?(request.correlation_id, "codex-turn:")
    assert request.request_metadata["native_http_claim_arm"] == "opening"
  end

  # A compaction request is built from the SAME `turn_metadata_state` as the turn
  # it compacts (`session.rs:686-701`, `turn_metadata.rs:169`), so both carry one
  # `turn_id`, and the bare claim encodes no endpoint. A compaction that reached
  # the turn arm would be refused as a duplicate of the turn it is compacting --
  # breaking every native HTTP turn that triggers a remote compaction, which is
  # strictly worse than the double spend the fence exists to stop.
  test "a turn and its own compaction are different requests, in both orders", %{conn: conn} do
    for {first, second} <- [{:turn, :compaction}, {:compaction, :turn}] do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.json_response(%{"id" => "resp_pair_one"}),
            FakeUpstream.json_response(%{"id" => "resp_pair_two"})
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      session = session_id()

      assert json_response(post_kind(conn, setup, session, first), 200)
      assert json_response(post_kind(conn, setup, session, second), 200)

      assert FakeUpstream.count(upstream) == 2
      requests = pool_requests(setup)
      assert length(requests) == 2
      assert requests |> Enum.map(& &1.correlation_id) |> Enum.uniq() |> length() == 2
    end
  end

  # The compaction arm is a different claim, not an absent one. A compaction
  # resent identically meets its own predecessor under its own HMAC domain and is
  # chained as one successor with its own settlement, never generated as an
  # unlinked second request: the released client resends a remote compaction
  # only when it never read its `response.completed`, retries it twice with the
  # same prompt, and three refusals failed the turn and lost the compaction
  # (findings#206 row 206-404; it was refused `409` here before).
  test "an identical compaction resend is chained as one successor", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_compaction"}),
          FakeUpstream.json_response(%{"id" => "resp_compaction_resent"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    assert json_response(post_kind(conn, setup, session, :compaction), 200)
    assert json_response(post_kind(conn, setup, session, :compaction), 200)

    assert FakeUpstream.count(upstream) == 2
    assert [request, resent] = pool_requests(setup)
    assert String.starts_with?(request.correlation_id, "codex-request:")
    assert request.request_metadata["native_http_claim_arm"] == "compaction"
    assert resent.correlation_id != request.correlation_id
    assert resent.request_metadata["client_resend"] == %{"predecessor_request_id" => request.id, "reason" => "failed_predecessor"}
  end

  # KNOWN MISS, documented deliberately: the compaction arm's own copy of the
  # boundary "a tool continuation resent with a grown body is NOT fenced" pins
  # below (findings#212, 212-54). A compaction is by construction a full-history
  # request, so its body is the thing most likely to differ between two
  # attempts -- and its claim has to be payload-scoped, because the only
  # alternative is the bare claim its own turn already holds. So a compaction
  # resent with a changed body is NOT fenced.
  test "a compaction resent with a changed body is NOT fenced (known miss)", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_compaction_one"}),
          FakeUpstream.json_response(%{"id" => "resp_compaction_two"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    compaction = fn text ->
      post_turn(conn, setup, session, @turn_id,
        where: :body,
        document: kind_metadata("compaction"),
        input: native_text_input(text) ++ [%{"type" => "compaction_trigger"}]
      )
    end

    assert json_response(compaction.("history as it stood"), 200)
    assert json_response(compaction.("history as it stood, plus one more item"), 200)

    assert FakeUpstream.count(upstream) == 2
    assert [one, two] = pool_requests(setup)
    assert String.starts_with?(one.correlation_id, "codex-request:")
    assert one.correlation_id != two.correlation_id
  end

  # THE ROW'S OWN FAILURE (findings#212, 212-48). A remote compaction is not a
  # URL: the released client has no `/compact` route anywhere in `codex-rs`, it
  # sends an ordinary Responses request carrying `request_kind: "compaction"`
  # with `ResponseItem::CompactionTrigger {}` appended
  # (`compact_remote_v2_attempt.rs:78`). The turn then RESUMES from the
  # compacted history, which ends with the compaction output item
  # (`compact.rs:600-660`), under the same `turn_id` and `request_kind: "turn"`.
  # Serving the compaction while refusing the resume left the turn just as dead
  # as refusing the compaction did, one request later.
  test "a turn, its remote compaction and the resume after it are three served requests", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_open"}),
          FakeUpstream.json_response(%{"id" => "resp_compaction"}),
          FakeUpstream.json_response(%{"id" => "resp_resume"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    assert %{"id" => "resp_open"} =
             json_response(post_turn(conn, setup, session, @turn_id, where: :body), 200)

    assert %{"id" => "resp_compaction"} =
             json_response(
               post_turn(conn, setup, session, @turn_id,
                 where: :body,
                 document: kind_metadata("compaction"),
                 input: native_text_input("history") ++ [%{"type" => "compaction_trigger"}]
               ),
               200
             )

    assert %{"id" => "resp_resume"} =
             json_response(
               post_turn(conn, setup, session, @turn_id,
                 where: :body,
                 input: compacted_history()
               ),
               200
             )

    assert FakeUpstream.count(upstream) == 3
    assert [open, compaction, resume] = pool_requests(setup)
    assert String.starts_with?(open.correlation_id, "codex-turn:")
    assert String.starts_with?(compaction.correlation_id, "codex-request:")
    assert open.request_metadata["native_http_claim_arm"] == "opening"
    assert compaction.request_metadata["native_http_claim_arm"] == "compaction"

    # The resume is named by the turn and an opaque digest of the compaction it
    # is resuming from, and by nothing else in the body -- clear of the claim the
    # opening request already holds, and immune to a rebuilt retry body.
    assert String.starts_with?(resume.correlation_id, "codex-resume:")
    assert resume.correlation_id != compaction.correlation_id
    assert resume.request_metadata["native_http_claim_arm"] == "post_compaction_resume"
  end

  # The compaction output item can be last, followed by the next user message,
  # followed by output the resume already delivered; it carries the
  # `compaction_summary` serde alias (`protocol/src/models.rs:1224`); and
  # `ResponseItem::ContextCompaction` is its sibling. None of those five
  # arrangements may collide with the turn's opening request.
  for {label, tail, item_type} <- [
        {"last", [], "compaction"},
        {"followed by an assistant message", [:assistant], "compaction"},
        {"under the compaction_summary alias", [], "compaction_summary"},
        {"as a context_compaction item", [], "context_compaction"}
      ] do
    test "a post-compaction resume with the compaction item #{label} is served", %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.json_response(%{"id" => "resp_arrangement_open"}),
            FakeUpstream.json_response(%{"id" => "resp_arrangement_resume"})
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      session = session_id()

      assert json_response(post_turn(conn, setup, session, @turn_id, where: :body), 200)

      input =
        native_text_input("before compaction") ++
          [%{"type" => unquote(item_type)}] ++ Enum.map(unquote(tail), &trailing_item/1)

      assert json_response(
               post_turn(conn, setup, session, @turn_id, where: :body, input: input),
               200
             )

      assert FakeUpstream.count(upstream) == 2
      assert [open, resume] = pool_requests(setup)
      assert String.starts_with?(open.correlation_id, "codex-turn:")
      assert String.starts_with?(resume.correlation_id, "codex-resume:")
    end
  end

  # A user message after the last compaction output item under the turn id of a
  # request already recorded. This test used to pin a refusal on the premise
  # that a user message always opens a new turn with a new `turn_id`; the
  # released client (0.156.1) drains user input steered into a running turn into
  # the SAME turn, right after a mid-turn compaction included
  # (`session/turn.rs` `can_drain_pending_input`), so the refusal failed a real
  # steered turn (findings#206 row 206-403). The opener's row records its
  # progress (the latest pivot and the user messages after it); this request's
  # differs, so it is not a rebuilt retry of the opener and is claimed as a
  # steered continuation, whose own identical resend stays refused.
  test "one turn id reused across a user message after a compaction is served as a steered continuation", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_reused_turn_id"}),
          FakeUpstream.json_response(%{"id" => "resp_steered_turn_id"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id, where: :body), 200)

    steered = fn ->
      post_turn(conn, setup, session, @turn_id,
        where: :body,
        input: native_text_input("before compaction") ++ [%{"type" => "compaction"}, trailing_item(:user)]
      )
    end

    assert json_response(steered.(), 200)
    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(steered.(), 409)

    assert FakeUpstream.count(upstream) == 2
    assert [opener, steer] = pool_requests(setup)
    assert String.starts_with?(opener.correlation_id, "codex-turn:")
    assert String.starts_with?(steer.correlation_id, "codex-resume:")
    assert steer.request_metadata["native_http_claim_arm"] == "steered_continuation"
  end

  # THE COST OF GETTING THE PREVIOUS TEST WRONG (findings#212, 212-48). Remote
  # compaction REPLACES the session history (`compact_remote_history.rs:118`,
  # `compact_remote_v2.rs:510`), so every turn for the rest of a session that
  # compacts once carries a compaction item. Naming those by their whole payload
  # loses the fence exactly where the row measured the spend: the client rebuilds
  # a cut turn's prompt from `clone_history()` with the delivered items appended,
  # so the retry is a different payload and buys a SECOND BILLED DISPATCH on a
  # predecessor that already succeeded. The turn's bare claim projects none of
  # that rebuilt body, so both requests keep the same identity.
  test "a turn in a compacted thread is still fenced against its own grown retry", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_compacted_thread_turn"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    # The shape of every turn after the session's first compaction: the retained
    # history, the compaction output the client pushed last, then this turn's
    # user message.
    history =
      native_text_input("retained history") ++
        [%{"type" => "compaction"}, trailing_item(:user)]

    assert json_response(
             post_turn(conn, setup, session, @turn_id, where: :body, input: history),
             200
           )

    # The cut retry: same turn, same compacted prefix, one delivered item more.
    grown = history ++ [trailing_item(:assistant)]

    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(
               post_turn(conn, setup, session, @turn_id, where: :body, input: grown),
               409
             )

    assert FakeUpstream.count(upstream) == 1
    assert [request] = pool_requests(setup)

    # The bare claim, exactly as an uncompacted turn takes -- which is also what
    # the websocket codec gives the same frame, so the two transports still
    # agree and a websocket-to-HTTPS failover of this turn still meets the fence.
    assert String.starts_with?(request.correlation_id, "codex-turn:")
  end

  # The control for the test above, and the fence's headline property: an
  # uncompacted turn's grown retry is refused by the bare claim. Both halves have
  # to hold, or the compacted branch is being compared against nothing.
  test "an uncompacted turn is fenced against its own grown retry", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_uncompacted_turn"})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    history = native_text_input("uncompacted history")

    assert json_response(
             post_turn(conn, setup, session, @turn_id, where: :body, input: history),
             200
           )

    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(
               post_turn(conn, setup, session, @turn_id,
                 where: :body,
                 input: history ++ [trailing_item(:assistant)]
               ),
               409
             )

    assert FakeUpstream.count(upstream) == 1
    assert [request] = pool_requests(setup)
    assert String.starts_with?(request.correlation_id, "codex-turn:")
  end

  # A turn resumed from a compaction still runs tools, so a continuation of the
  # resume carries a compaction item AND a tool result. All four requests of that
  # turn must be served and must be named differently from one another.
  test "a tool continuation of a post-compaction resume is served", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_a1_open"}),
          FakeUpstream.json_response(%{"id" => "resp_a1_compaction"}),
          FakeUpstream.json_response(%{"id" => "resp_a1_resume"}),
          FakeUpstream.json_response(%{"id" => "resp_a1_continuation"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id, where: :body), 200)

    assert json_response(
             post_turn(conn, setup, session, @turn_id,
               where: :body,
               document: kind_metadata("compaction"),
               input: native_text_input("history") ++ [%{"type" => "compaction_trigger"}]
             ),
             200
           )

    resume_input = compacted_history()

    assert json_response(
             post_turn(conn, setup, session, @turn_id, where: :body, input: resume_input),
             200
           )

    assert json_response(
             post_turn(conn, setup, session, @turn_id,
               where: :body,
               input:
                 resume_input ++
                   [
                     %{
                       "type" => "function_call_output",
                       "call_id" => "call_212_after_compaction",
                       "output" => "tool result"
                     }
                   ]
             ),
             200
           )

    assert FakeUpstream.count(upstream) == 4
    requests = pool_requests(setup)
    assert length(requests) == 4
    assert requests |> Enum.map(& &1.correlation_id) |> Enum.uniq() |> length() == 4
  end

  # The other direction of the same change: serving the resume must not stop the
  # fence catching a genuine duplicate of it.
  test "an identical post-compaction resume is still refused", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_resume_open"}),
          FakeUpstream.json_response(%{"id" => "resp_resume_once"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id, where: :body), 200)

    resume = fn ->
      post_turn(conn, setup, session, @turn_id, where: :body, input: compacted_history())
    end

    assert json_response(resume.(), 200)

    before = pool_accounting_counts(setup)
    dispatched = FakeUpstream.count(upstream)

    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(resume.(), 409)

    assert FakeUpstream.count(upstream) == dispatched
    assert pool_accounting_counts(setup) == before
  end

  test "a post-compaction retry advanced by delivered output is served once", %{conn: conn} do
    delivered_item = Map.put(trailing_item(:assistant), "id", "msg_resume_progress")

    second_delivered_item = %{
      "type" => "reasoning",
      "id" => "rs_resume_progress",
      "summary" => [%{"type" => "summary_text", "text" => "continued"}],
      "encrypted_content" => "synthetic-encrypted-content"
    }

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_resume_progress_open"}),
          FakeUpstream.sse_stream(
            [
              {"response.output_item.done", %{"type" => "response.output_item.done", "item" => delivered_item}},
              {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "not delivered"}}
            ],
            done: false
          ),
          FakeUpstream.sse_stream(
            [
              {"response.output_item.done",
               %{
                 "type" => "response.output_item.done",
                 "item" => second_delivered_item
               }},
              {"response.reasoning_text.delta", %{"type" => "response.reasoning_text.delta", "delta" => "not delivered"}}
            ],
            done: false
          ),
          stream_success_sse()
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id, where: :body), 200)

    resume_input = compacted_history()

    payload =
      setup
      |> turn_payload(input: resume_input, stream: true)
      |> put_body_document(turn_metadata(@turn_id))

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    codex_session = pool_session!(setup, session)

    request_options =
      %{
        codex_session: codex_session,
        upstream_endpoint: "/backend-api/codex/responses",
        transport: "http_sse"
      }
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert {:ok, %{stream: stream}} =
             Gateway.execute(auth, "/backend-api/codex/responses", payload, request_options)

    delivered_event =
      "event: response.output_item.done\ndata: " <>
        CodexPooler.JSON.encode!(%{
          "type" => "response.output_item.done",
          "item" => delivered_item
        }) <> "\n\n"

    stream_conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {adapter, adapter_payload} = stream_conn.adapter

    closing_state = %{
      adapter: adapter,
      payload: adapter_payload,
      close_after: delivered_event,
      closed?: false
    }

    assert {:ok, _closed_conn} =
             stream.(%{stream_conn | adapter: {ClosingAdapter, closing_state}})

    retry_item =
      Map.put(delivered_item, "internal_chat_message_metadata_passthrough", %{
        "turn_id" => @turn_id,
        "create_time" => 1_789_000_000.25,
        "content_item_kinds" => ["user.text"]
      })

    advanced_input = resume_input ++ [retry_item]

    altered_item = %{
      retry_item
      | "content" => [%{"type" => "output_text", "text" => "altered"}]
    }

    before_refusals = pool_accounting_counts(setup)

    # The resume followed by a user message is no longer probed here: that is a
    # steered continuation of the turn, served under its own claim (findings#206
    # row 206-403, `backend_codex_http_steer_and_compaction_retry_test.exs`),
    # not a changed suffix of this resume.
    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(
               post_turn(conn, setup, session, @turn_id,
                 where: :body,
                 input: resume_input ++ [altered_item],
                 stream: true
               ),
               409
             )

    assert pool_accounting_counts(setup) == before_refusals

    assert {:ok, %{stream: second_stream}} =
             Gateway.execute(
               auth,
               "/backend-api/codex/responses",
               put_body_document(
                 turn_payload(setup, input: advanced_input, stream: true),
                 turn_metadata(@turn_id)
               ),
               request_options
             )

    second_delivered_event =
      "event: response.output_item.done\ndata: " <>
        CodexPooler.JSON.encode!(%{
          "type" => "response.output_item.done",
          "item" => second_delivered_item
        }) <> "\n\n"

    second_closing_state = %{closing_state | close_after: second_delivered_event}

    assert {:ok, _closed_conn} =
             second_stream.(%{stream_conn | adapter: {ClosingAdapter, second_closing_state}})

    second_retry_item =
      Map.put(second_delivered_item, "internal_chat_message_metadata_passthrough", %{
        "turn_id" => @turn_id,
        "create_time" => 1_789_000_001.25
      })

    completed_input = advanced_input ++ [second_retry_item]

    assert response(
             post_turn(conn, setup, session, @turn_id,
               where: :body,
               input: completed_input,
               stream: true
             ),
             200
           ) =~ "response.completed"

    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(
               post_turn(conn, setup, session, @turn_id,
                 where: :body,
                 input: completed_input,
                 stream: true
               ),
               409
             )

    assert FakeUpstream.count(upstream) == 4

    assert [open, first_resume, second_resume, completed_resume] = pool_requests(setup)
    assert open.request_metadata["native_http_claim_arm"] == "opening"
    assert first_resume.request_metadata["native_http_claim_arm"] == "post_compaction_resume"
    assert second_resume.request_metadata["native_http_claim_arm"] == "post_compaction_resume"
    assert completed_resume.request_metadata["native_http_claim_arm"] == "post_compaction_resume"
    assert first_resume.status == "failed"
    assert first_resume.last_error_code == "client_disconnected"
    assert second_resume.status == "failed"
    assert second_resume.last_error_code == "client_disconnected"
    assert get_in(first_resume.request_metadata, ["client_resend"]) == nil

    assert %{
             "version" => 1,
             "output_item_done_count" => 1,
             "digest" => progress_digest
           } =
             Repo.one!(from(a in Attempt, where: a.request_id == ^first_resume.id)).response_metadata[
               "native_http_resume_progress"
             ]

    assert is_binary(progress_digest) and byte_size(progress_digest) == 43
    assert first_resume.correlation_id != second_resume.correlation_id
    assert second_resume.correlation_id != completed_resume.correlation_id
    assert String.starts_with?(first_resume.correlation_id, "codex-resume:")
    assert String.starts_with?(second_resume.correlation_id, "codex-request-retry:")
    assert String.starts_with?(completed_resume.correlation_id, "codex-request-retry:")
  end

  test "a resume is anchored only by the latest compaction pivot", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_latest_pivot"}),
          FakeUpstream.json_response(%{"id" => "resp_different_latest_pivot"})
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = session_id()

    old = %{"type" => "compaction", "encrypted_content" => "old"}
    latest = %{"type" => "compaction", "encrypted_content" => "latest"}

    assert json_response(
             post_turn(conn, setup, session, @turn_id,
               where: :body,
               input: [old, latest]
             ),
             200
           )

    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(
               post_turn(conn, setup, session, @turn_id,
                 where: :body,
                 input: [latest, %{"type" => "future_output"}, "malformed"]
               ),
               409
             )

    assert json_response(
             post_turn(conn, setup, session, @turn_id,
               where: :body,
               input: [%{latest | "encrypted_content" => "different-latest"}]
             ),
             200
           )

    assert FakeUpstream.count(upstream) == 2
    assert [first, second] = pool_requests(setup)
    assert String.starts_with?(first.correlation_id, "codex-resume:")
    assert String.starts_with?(second.correlation_id, "codex-resume:")
    refute first.correlation_id == second.correlation_id
  end

  # A client that sends only the bounded header copy resolved its `request_kind`
  # from the header while the continuation discriminator read the body alone, so
  # every tool continuation of its turn landed on the claim the opening request
  # already held and was refused `409` (findings#212, 212-49). Both carriers now
  # go through one resolver.
  for carrier <- [:header, :body] do
    test "a tool continuation of a turn is served, not fenced against its own turn (#{carrier})",
         %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.json_response(%{"id" => "resp_open_before_tool"}),
            FakeUpstream.json_response(%{"id" => "resp_first_tool_round"}),
            FakeUpstream.json_response(%{"id" => "resp_second_tool_round"})
          ])
        )

      setup = gateway_setup(upstream)
      session = session_id()

      assert json_response(
               post_turn(conn, setup, session, @turn_id, where: unquote(carrier)),
               200
             )

      for call_id <- ["call_212_first", "call_212_second"] do
        assert json_response(
                 post_turn(conn, setup, session, @turn_id,
                   where: unquote(carrier),
                   input: [
                     %{
                       "type" => "function_call_output",
                       "call_id" => call_id,
                       "output" => "tool result"
                     }
                   ]
                 ),
                 200
               )
      end

      assert FakeUpstream.count(upstream) == 3
      assert [open | continuations] = pool_requests(setup)
      assert String.starts_with?(open.correlation_id, "codex-turn:")
      assert open.request_metadata["native_http_claim_arm"] == "opening"

      for continuation <- continuations do
        assert String.starts_with?(continuation.correlation_id, "codex-request:")
        assert continuation.request_metadata["native_http_claim_arm"] == "tool_continuation"
      end
    end
  end

  # A `prewarm` is built from the turn's own `TurnMetadataState` and so carries
  # the turn's `turn_id` (`session_startup_prewarm.rs:303-310`); a `memory`
  # request mints its own (`turn_metadata.rs:133-139`). Neither may take the
  # turn's bare claim, and neither has to give up being fenced to avoid it: each
  # is named by its payload inside a domain named by its kind.
  for kind <- ["prewarm", "memory"] do
    test "a #{kind} request sharing the turn id is clear of the turn but still fenced", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.json_response(%{"id" => "resp_kind_one"}),
            FakeUpstream.json_response(%{"id" => "resp_turn_after_kind"})
          ])
        )

      setup = gateway_setup(upstream)
      session = session_id()

      kind_request = fn ->
        post_turn(conn, setup, session, @turn_id, document: kind_metadata(unquote(kind)))
      end

      assert json_response(kind_request.(), 200)
      # It does not collide with the turn that shares its id.
      assert json_response(post_turn(conn, setup, session, @turn_id), 200)
      # And it is not unfenced: an identical resend of it is still refused.
      assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(kind_request.(), 409)

      assert FakeUpstream.count(upstream) == 2
      assert [kind_row, turn_row] = pool_requests(setup)
      assert String.starts_with?(kind_row.correlation_id, "codex-kind:")
      assert String.starts_with?(turn_row.correlation_id, "codex-turn:")
      assert kind_row.request_metadata["native_http_claim_arm"] == unquote(kind)
      assert turn_row.request_metadata["native_http_claim_arm"] == "opening"
    end
  end

  # A kind with no rule here, and a document that omits the field, are guessed
  # at by nobody: they keep the generated correlation id and today's behaviour,
  # per kind rather than by reading the selector.
  for {label, document} <- [
        {"an unknown kind", CodexPooler.JSON.encode!(%{"turn_id" => @turn_id, "request_kind" => "surprise"})},
        {"no request_kind at all", CodexPooler.JSON.encode!(%{"turn_id" => @turn_id})}
      ] do
    test "#{label} keeps today's behaviour and a generated correlation id", %{conn: conn} do
      assert_unfenced(conn, fn conn, setup, session ->
        conn
        |> auth(setup)
        |> put_req_header(@session_header, session)
        |> put_req_header(@metadata_header, unquote(document))
        |> post("/backend-api/codex/responses", turn_payload(setup))
      end)
    end
  end

  # The fence must not have a one-string off switch. The released client emits
  # the lowercase literal, but any intermediary that normalises the document
  # would otherwise disable the whole thing with a case change or a stray space.
  for {label, kind} <- [{"upper case", "TURN"}, {"a trailing space", "turn "}] do
    test "a request_kind differing only by #{label} is still fenced", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_kind_case"}))
      setup = gateway_setup(upstream)
      session = session_id()

      document =
        CodexPooler.JSON.encode!(%{"turn_id" => @turn_id, "request_kind" => unquote(kind)})

      assert json_response(post_turn(conn, setup, session, @turn_id, document: document), 200)

      assert %{"error" => %{"code" => "duplicate_turn"}} =
               json_response(post_turn(conn, setup, session, @turn_id, document: document), 409)

      assert FakeUpstream.count(upstream) == 1
      assert [request] = pool_requests(setup)
      assert String.starts_with?(request.correlation_id, "codex-turn:")
    end
  end

  # KNOWN MISS, documented deliberately. A tool-result continuation inside a
  # turn must be named by its payload, or the several requests of one turn would
  # collide with each other -- so a continuation whose retry body has grown is
  # NOT fenced. The websocket path has exactly the same miss for exactly the
  # same reason (`websocket_codec.ex:938-965`); this test pins the boundary so
  # it cannot change silently.
  test "a tool continuation resent with a grown body is NOT fenced (known miss)", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_continuation_one"}),
          FakeUpstream.json_response(%{"id" => "resp_continuation_two"})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    post_continuation = fn input ->
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header(@session_header, session)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => input,
        "client_metadata" => %{"x-codex-turn-metadata" => turn_metadata(@turn_id)}
      })
    end

    # A native HTTP tool continuation carries the full history: the provider
    # refuses `previous_response_id` over HTTP (findings#232 rows 232-275 and
    # 232-276), and the released client anchors only on its websocket.
    tool_output = [
      %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "run the tool"}]},
      %{"type" => "function_call", "call_id" => "call_212_continuation", "name" => "sample_tool", "arguments" => "{}"},
      %{
        "type" => "function_call_output",
        "call_id" => "call_212_continuation",
        "output" => "tool result"
      }
    ]

    assert json_response(post_continuation.(tool_output), 200)

    grown =
      tool_output ++
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "delivered before the cut"}]
          }
        ]

    assert json_response(post_continuation.(grown), 200)

    # Two dispatches: the grown body is a different payload-scoped claim. This
    # is the residual, not a regression -- before the fence existed both of
    # these dispatched too.
    assert FakeUpstream.count(upstream) == 2
    requests = pool_requests(setup)
    assert length(requests) == 2

    for %Request{correlation_id: correlation_id} <- requests do
      assert String.starts_with?(correlation_id, "codex-request:")
    end
  end

  # The cut cohort retries up to the client's whole budget, and a transport
  # switch resets that counter, so one turn can reach double digits of
  # dispatches. One refusal is not the contract; every resend refusing is.
  test "every further resend of one turn is refused, not only the second", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_repeated_resend"}))
    setup = gateway_setup(upstream)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id), 200)

    for _resend <- 1..5 do
      assert %{"error" => %{"code" => "duplicate_turn"}} =
               json_response(post_turn(conn, setup, session, @turn_id), 409)
    end

    assert FakeUpstream.count(upstream) == 1
    assert length(pool_requests(setup)) == 1
  end

  test "two genuinely different native HTTP turns both dispatch", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_turn_one"}),
          FakeUpstream.json_response(%{"id" => "resp_turn_two"})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    assert %{"id" => "resp_turn_one"} =
             json_response(post_turn(conn, setup, session, "turn_one"), 200)

    assert %{"id" => "resp_turn_two"} =
             json_response(post_turn(conn, setup, session, "turn_two"), 200)

    assert FakeUpstream.count(upstream) == 2
    requests = pool_requests(setup)
    assert length(requests) == 2
    assert requests |> Enum.map(& &1.correlation_id) |> Enum.uniq() |> length() == 2
  end

  # A brand-new path must not log under the old path's name. Triage greps for
  # "websocket replay rejection" and for `transport=websocket`; a native HTTP
  # refusal that claimed either would send an operator looking for a websocket
  # session that never existed.
  @tag capture_log: false
  test "a native HTTP refusal is logged as native http, not as websocket", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_log_label"}))
    setup = gateway_setup(upstream)
    session = session_id()

    assert json_response(post_turn(conn, setup, session, @turn_id), 200)

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    logs =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert %{"error" => %{"code" => "duplicate_turn"}} =
                 json_response(post_turn(conn, setup, session, @turn_id), 409)
      end)

    assert logs =~ "native http replay rejection"
    assert logs =~ "stage=native_http_turn_claim"
    assert logs =~ "transport=http_json"
    refute logs =~ "websocket replay rejection"
    refute logs =~ "transport=websocket"
  end

  # The refusal writes no request row, so request-log counts never see it; the
  # duplicate-turn counter is the only operator signal it leaves (findings#225).
  test "a native HTTP duplicate_turn refusal is counted by stage and transport", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_counted_refusal"}))
    setup = gateway_setup(upstream)
    session = session_id()
    test_pid = self()
    handler_id = "duplicate-turn-refused-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :duplicate_turn, :refused],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:duplicate_turn_refused, measurements, metadata})
        end,
        nil
      )

    assert json_response(post_turn(conn, setup, session, @turn_id), 200)
    refute_received {:duplicate_turn_refused, _measurements, _metadata}

    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(post_turn(conn, setup, session, @turn_id), 409)

    assert_received {:duplicate_turn_refused, %{count: 1}, %{stage: "native_http_turn_claim", transport: "http"}}
    refute_received {:duplicate_turn_refused, _measurements, _metadata}
    assert length(pool_requests(setup)) == 1
  end

  # `FailedPredecessorResend.scoped?/2` requires `transport == "websocket"` of
  # the PREDECESSOR ROW, not of the request being served. The bare `codex-turn:`
  # claim is payload-independent and is the one claim that coincides across the
  # two transports, so a websocket predecessor really can be judged for an HTTP
  # resend -- and then the HTTP refusal reports that predecessor's disposition,
  # not the `authorization_changed` an HTTP-predecessor refusal reports.
  #
  # This is the ticket's own headline cohort: a websocket turn cut by a rollout
  # drain after visible output, whose client falls back to HTTPS and resends.
  # Three rounds of review and one runbook revision asserted this could not
  # happen, so it is pinned here (findings#212, rows 212-44 and 212-54). One
  # non-`authorization_changed` disposition is enough: the HTTP stage passes
  # whatever `FailedPredecessorResend.resolve/2` returned straight through, so
  # the whole vocabulary reaches it or none of it does.
  # Parameterised over BOTH histories on purpose. The compacted row is the one
  # that broke: while a compacted turn's opener took a payload-scoped claim, the
  # websocket codec still gave the same frame the bare claim, the two legs no
  # longer met, and the fallback bought a second billed dispatch for every
  # session that had compacted once. Driving only the uncompacted row is how
  # that shipped.
  for history <- [:uncompacted, :compacted] do
    @tag capture_log: false
    test "a #{history} HTTPS fallback of a drained websocket turn is refused", %{conn: conn} do
      upstream = start_upstream(stream_success_sse())
      setup = gateway_setup(upstream, compact?: true)
      session = session_id()

      fallback_input =
        case unquote(history) do
          :uncompacted -> native_text_input("fallback history")
          :compacted -> compacted_session_turn()
        end

      # Establish the persisted session, then ask the production websocket
      # writer for the exact claim it would put on this frame. The predecessor
      # is reserved through the websocket accounting boundary under that claim;
      # no HTTP-written claim is relabelled into a websocket row.
      assert response(
               post_turn(conn, setup, session, "session_seed_#{unquote(history)}", stream: true),
               200
             )

      codex_session = pool_session!(setup, session)
      claim = websocket_request_claim!(setup, codex_session, @turn_id, fallback_input)
      predecessor = reserve_delivered_websocket_predecessor!(setup, codex_session, claim)

      assert %{"error" => %{"code" => "duplicate_turn"}} =
               json_response(
                 post_turn(conn, setup, session, @turn_id,
                   stream: true,
                   where: :body,
                   input: fallback_input
                 ),
                 409
               )

      assert FakeUpstream.count(upstream) == 1
      assert Repo.get!(Request, predecessor.id).correlation_id == claim

      # The bare claim is the one claim that coincides across the two
      # transports, which is what makes the failover fenceable at all.
      assert String.starts_with?(claim, "codex-turn:")
    end
  end

  # A cut and its retry do not only differ in `input`: the client re-enters the
  # request loop and rebuilds the whole `Prompt` from live session state, so
  # `tools`, `instructions` and the scalars can all move. A claim that is an
  # HMAC over a payload projection misses whenever they do -- ledger row 212-20
  # is the record of that -- so a compacted turn must not be named by one.
  for {label, history} <- [{"uncompacted", :uncompacted}, {"compacted", :compacted}] do
    test "a #{label} turn is fenced across a changed non-input field", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_scalar"}))
      setup = gateway_setup(upstream, compact?: true)
      session = session_id()

      input =
        case unquote(history) do
          :uncompacted -> native_text_input("scalar history")
          :compacted -> compacted_session_turn()
        end

      post_with = fn extra ->
        conn
        |> recycle()
        |> auth(setup)
        |> put_req_header(@session_header, session)
        |> post(
          "/backend-api/codex/responses",
          Map.merge(
            %{
              "model" => setup.model.exposed_model_id,
              "input" => input,
              "client_metadata" => %{@metadata_header => turn_metadata(@turn_id)}
            },
            extra
          )
        )
      end

      assert json_response(post_with.(%{"parallel_tool_calls" => true}), 200)

      assert %{"error" => %{"code" => "duplicate_turn"}} =
               json_response(post_with.(%{"parallel_tool_calls" => false}), 409)

      assert FakeUpstream.count(upstream) == 1
      assert [row] = pool_requests(setup)
      assert String.starts_with?(row.correlation_id, "codex-turn:")
    end
  end

  @tag capture_log: false
  test "a native HTTP refusal reports a websocket predecessor's own disposition", %{conn: conn} do
    upstream = start_upstream(stream_success_sse())
    setup = gateway_setup(upstream)
    session = session_id()

    # The predecessor row is written by the real streaming path, so its turn
    # carries a genuine `first_visible_output_at`; only the two fields that make
    # it a drained websocket turn are then set.
    assert response(post_turn(conn, setup, session, @turn_id, stream: true), 200)
    assert [predecessor] = pool_requests(setup)

    {1, _} =
      Repo.update_all(
        from(r in Request, where: r.id == ^predecessor.id),
        set: [transport: "websocket", status: "failed", last_error_code: "owner_drained"]
      )

    # The global level has to come down, not just the capture level: the
    # `:level` option to `capture_log/2` filters what is CAPTURED, while the
    # global level decides whether `Logger.info/1` emits anything at all. Tried
    # without it and the capture came back empty. `on_exit` runs on failure and
    # on exit, so the only window that leaks is a hard VM kill.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    logs =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert %{"error" => %{"code" => "duplicate_turn"}} =
                 json_response(post_turn(conn, setup, session, @turn_id, stream: true), 409)
      end)

    assert logs =~ "stage=native_http_turn_claim"
    assert logs =~ "resend_disposition=terminal_predecessor"
    refute logs =~ "resend_disposition=authorization_changed"

    # The refusal still costs nothing.
    assert FakeUpstream.count(upstream) == 1
    assert length(pool_requests(setup)) == 1
  end

  # The fence must never reach a client that does not send the metadata. These
  # two shapes are the fail-open contract: behaviour is exactly what it was
  # before the fence existed, including the second dispatch.
  test "a native HTTP request with no turn metadata keeps today's behaviour", %{conn: conn} do
    assert_unfenced(conn, fn conn, setup, session ->
      conn
      |> auth(setup)
      |> put_req_header(@session_header, session)
      |> post("/backend-api/codex/responses", turn_payload(setup))
    end)
  end

  test "a native HTTP request with malformed turn metadata keeps today's behaviour", %{
    conn: conn
  } do
    assert_unfenced(conn, fn conn, setup, session ->
      conn
      |> auth(setup)
      |> put_req_header(@session_header, session)
      |> put_req_header(@metadata_header, "not-json-metadata")
      |> post("/backend-api/codex/responses", turn_payload(setup))
    end)
  end

  # `/v1` is a translated SDK surface, not a native Codex turn, and its clients
  # own their own retry semantics. A `x-codex-` header arriving there is
  # forwarded metadata, never a turn identity, so the fence must not reach it
  # even when the header is present and well formed.
  test "a translated /v1 request carrying turn metadata is not fenced", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_v1_one"}),
          FakeUpstream.json_response(%{"id" => "resp_v1_two"})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    post_v1 = fn ->
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header(@session_header, session)
      |> put_req_header(@metadata_header, turn_metadata(@turn_id))
      |> post("/v1/responses", turn_payload(setup))
    end

    assert json_response(post_v1.(), 200)
    assert json_response(post_v1.(), 200)

    assert FakeUpstream.count(upstream) == 2
    assert length(pool_requests(setup)) == 2
  end

  # A turn identity is scoped by the codex session, exactly as the websocket
  # claim is, so the same `turn_id` under a different session is a different
  # turn and must not be fenced.
  test "the same turn id under a different session is a different turn", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_session_one"}),
          FakeUpstream.json_response(%{"id" => "resp_session_two"})
        ])
      )

    setup = gateway_setup(upstream)

    assert json_response(post_turn(conn, setup, session_id(), @turn_id), 200)
    assert json_response(post_turn(conn, setup, session_id(), @turn_id), 200)

    assert FakeUpstream.count(upstream) == 2
    assert length(pool_requests(setup)) == 2
    assert Repo.aggregate(CodexSession, :count) == 2
  end

  defp assert_unfenced(conn, request) do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_unfenced_one"}),
          FakeUpstream.json_response(%{"id" => "resp_unfenced_two"})
        ])
      )

    setup = gateway_setup(upstream)
    session = session_id()

    assert json_response(request.(recycle(conn), setup, session), 200)
    assert json_response(request.(recycle(conn), setup, session), 200)

    assert FakeUpstream.count(upstream) == 2
    requests = pool_requests(setup)
    assert length(requests) == 2

    for %Request{correlation_id: correlation_id} <- requests do
      assert {:ok, _uuid} = Ecto.UUID.cast(correlation_id)
    end

    assert Enum.all?(requests, fn request ->
             not Map.has_key?(request.request_metadata, "native_http_claim_arm")
           end)
  end

  # `:where` selects the carrier: `:header` sends only the bounded header copy,
  # `:body` sends only the canonical `client_metadata` document the released
  # client puts in the body. Both must classify the request identically.
  defp post_turn(conn, setup, session, turn_id, opts \\ []) do
    document = Keyword.get(opts, :document, turn_metadata(turn_id))
    where = Keyword.get(opts, :where, :header)

    payload =
      case where do
        :body -> put_body_document(turn_payload(setup, opts), document)
        :header -> turn_payload(setup, opts)
      end

    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header(@session_header, session)
    |> then(&if where == :header, do: put_req_header(&1, @metadata_header, document), else: &1)
    |> post(Keyword.get(opts, :path, "/backend-api/codex/responses"), payload)
  end

  defp put_body_document(payload, document),
    do: Map.put(payload, "client_metadata", %{@metadata_header => document})

  defp turn_payload(setup, opts \\ []) do
    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => Keyword.get(opts, :input, native_text_input("duplicate turn fence"))
    }

    if Keyword.get(opts, :stream, false), do: Map.put(payload, "stream", true), else: payload
  end

  defp post_kind(conn, setup, session, :turn),
    do: post_turn(conn, setup, session, @turn_id)

  defp post_kind(conn, setup, session, :compaction) do
    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header(@session_header, session)
    |> put_req_header(
      @metadata_header,
      CodexPooler.JSON.encode!(%{
        "turn_id" => @turn_id,
        "request_kind" => "compaction",
        "window_id" => "compaction-window",
        "context_window_id" => Ecto.UUID.generate()
      })
    )
    |> post("/backend-api/codex/responses/compact", turn_payload(setup))
  end

  defp turn_metadata(turn_id),
    do: CodexPooler.JSON.encode!(%{"turn_id" => turn_id, "request_kind" => "turn"})

  defp kind_metadata(kind, turn_id \\ @turn_id),
    do: CodexPooler.JSON.encode!(%{"turn_id" => turn_id, "request_kind" => kind})

  # What the client resumes a turn with after a remote compaction: the compacted
  # history, whose last item is the compaction output (`compact.rs:600-660`).
  defp compacted_history,
    do: native_text_input("before compaction") ++ [%{"type" => "compaction"}]

  # A turn of a session that has compacted once: the retained history, the
  # compaction output the client pushed last, then this turn's user message.
  defp compacted_session_turn,
    do: native_text_input("retained history") ++ [%{"type" => "compaction"}, trailing_item(:user)]

  defp tool_round,
    do: [%{"type" => "function_call_output", "call_id" => "call_212_shape", "output" => "ok"}]

  defp trailing_item(:user),
    do: %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "next"}]
    }

  defp trailing_item(:assistant),
    do: %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "already delivered"}]
    }

  defp pool_requests(setup) do
    Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: r.admitted_at))
  end

  defp pool_accounting_counts(setup) do
    request_ids =
      Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, select: r.id))

    %{
      requests: length(request_ids),
      attempts: Repo.aggregate(from(a in Attempt, where: a.request_id in ^request_ids), :count, :id),
      ledger: Repo.aggregate(from(l in LedgerEntry, where: l.request_id in ^request_ids), :count, :id)
    }
  end

  defp compatibility_claim_prefix(kind) do
    CompatibilityMatrix.by_slug!(:duplicate_turn_fence).duplicate_turn.claim_by_request_kind
    |> Map.fetch!(kind)
    |> Map.fetch!(:prefix)
  end

  defp pool_session!(setup, session_key) do
    Repo.one!(
      from(s in CodexSession,
        where: s.pool_id == ^setup.pool.id and s.session_key == ^session_key
      )
    )
  end

  defp websocket_request_claim!(setup, %CodexSession{} = session, turn_id, input) do
    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true,
      "client_metadata" => %{
        "turn_id" => turn_id,
        @metadata_header => turn_metadata(turn_id)
      }
    }

    options =
      %{
        transport: "websocket",
        upstream_websocket_session: self(),
        codex_session: session
      }
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> RequestOptions.put_model_serving_mode(%{
        configured_mode: "full",
        effective_mode: "full",
        source: "override"
      })

    assert {:ok, prepared} =
             WebsocketCodec.prepare_frame(CodexPooler.JSON.encode!(payload), options, fn _ ->
               :ok
             end)

    prepared.request_options.continuity.request_claim_key
  end

  defp reserve_delivered_websocket_predecessor!(setup, session, claim) do
    assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, %{request: predecessor}} =
             Accounting.claim_websocket_turn(auth, setup.model, %{
               endpoint: "/backend-api/codex/responses",
               correlation_id: claim,
               codex_session: session,
               requested_model: setup.model.exposed_model_id
             })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update!(
      Ecto.Changeset.change(predecessor,
        status: "succeeded",
        usage_status: "usage_known",
        response_status_code: 200,
        completed_at: now
      )
    )
  end

  defp session_id, do: "codex-session-" <> unique_suffix()

  defp thread_id, do: "codex-thread-" <> unique_suffix()

  # One turn of a Codex thread, sent the way the released client sends it after
  # `window_number` compactions: the stable `session-id`, the window the client
  # currently holds, and the canonical document naming the thread the window
  # belongs to.
  defp post_window_turn(conn, setup, session, thread, window_number, turn_id) do
    document =
      CodexPooler.JSON.encode!(%{
        "turn_id" => turn_id,
        "thread_id" => thread,
        "window_id" => window_id(thread, window_number),
        "window_number" => window_number,
        "request_kind" => "turn"
      })

    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header(@session_header, session)
    |> put_req_header("x-codex-window-id", window_id(thread, window_number))
    |> put_req_header(@metadata_header, document)
    |> post("/backend-api/codex/responses", turn_payload(setup))
  end

  defp window_id(thread, window_number), do: "#{thread}:#{window_number}"

  defp window_session_key(thread, window_number) do
    digest =
      :crypto.hash(:sha256, window_id(thread, window_number))
      |> Base.encode16(case: :lower)

    "x-codex-window-id:" <> digest
  end
end
