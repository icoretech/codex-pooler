defmodule CodexPooler.Accounting.TurnClaimResendChainTest do
  # A resend under a websocket turn claim (`codex-turn:`) is chained onto the
  # request that holds the claim when that request ended in a shape the resend
  # policy admits, and it is linked to it. With owner forwarding off there is
  # no replay, so a successor cut before any output reached the client is
  # itself a pre-visible disconnect, and the released client resends the turn
  # once more. The policy refused every chain node a client-retry link names,
  # the chain's own edge included, so that resend met `409 duplicate_turn`
  # (findings#206 row 206-519). A chain node may now carry exactly the chain's
  # own edges: the link from the node before it and the link to the request
  # holding the claim derived from it. Any other link still keeps the fence:
  # it names a successor admitted under another claim (the owner's
  # `client-retry-v1:` preflight), and chaining past it would admit a second
  # successor of one predecessor.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures, only: [attempt_fixture: 3]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request, RequestClientRetryLink}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  setup do
    setup = accounting_setup()
    session = insert_session!(setup)
    claim = "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    witness = ClientRetry.original_witness!(:crypto.strong_rand_bytes(32), 0)
    opts = %{endpoint: @endpoint, correlation_id: claim, codex_session: session, native_client_retry_witness: witness, requested_model: setup.model.exposed_model_id}
    %{setup: setup, session: session, claim: claim, opts: opts}
  end

  test "a resend after each successor is cut before any output chains onto that successor", %{setup: setup, session: session, claim: claim, opts: opts} do
    assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, original)

    chain =
      Enum.reduce(1..3, [original], fn _step, [predecessor | _earlier] = chain ->
        assert {:ok, %{request: successor, client_resend: %{predecessor_request_id: predecessor_id, predecessor_shape: :previsible_disconnect}}} =
                 Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

        assert predecessor_id == predecessor.id
        assert {:ok, successor.correlation_id} == ClientRetry.deterministic_failed_predecessor_claim(predecessor.correlation_id, predecessor.id)
        assert successor.request_metadata["client_resend"]["predecessor_request_id"] == predecessor.id
        assert Repo.exists?(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^predecessor.id and link.successor_request_id == ^successor.id))
        previsible_cut!(setup, session, successor)
        [successor | chain]
      end)

    assert length(chain) == 4
    assert original.correlation_id == claim
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 4
  end

  test "the successor is still refused while the cut successor's attempt is live", %{setup: setup, session: session, opts: opts} do
    assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, original)
    assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

    attempt_fixture(successor, setup.assignment, %{status: "in_progress", completed_at: nil, transport: "websocket", usage_status: "usage_pending"})
    Repo.update!(Ecto.Changeset.change(successor, status: "in_progress"))

    assert {:error, %{code: :duplicate_request, resend_disposition: :active_predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
  end

  # The released client's retries of one turn are paced by its own backoff and
  # by how long each successor ran before it was cut, so the whole chain can
  # outlast the thirty-second retry window of its first request. A node the
  # walk passes through already had its successor admitted inside its window;
  # only the node the resend chains onto is held to it.
  test "the retry window binds the node the resend chains onto, not the nodes the walk passes", %{setup: setup, session: session, opts: opts} do
    assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, original)
    assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, successor)
    expire_retry_window!(original)

    assert {:ok, %{request: next, client_resend: %{predecessor_request_id: predecessor_id}}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert predecessor_id == successor.id
    previsible_cut!(setup, session, next)
    expire_retry_window!(next)

    assert {:error, %{code: :duplicate_request, resend_disposition: :retry_expired}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 3
  end

  test "a link to a successor admitted under another claim keeps the fence", %{setup: setup, session: session, opts: opts} do
    assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, original)
    assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, successor)

    # The owner's client-retry preflight chained the cut successor onto a
    # request of its own claim domain before this resend arrived.
    foreign = foreign_request!(setup)
    _link = ClientRetry.insert_link!(successor, foreign, DateTime.utc_now())

    assert {:error, %{code: :duplicate_request, resend_disposition: :terminal_predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 3
  end

  test "a link naming the chain's first request as another request's successor keeps the fence", %{setup: setup, session: session, opts: opts} do
    assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, original)
    _link = ClientRetry.insert_link!(foreign_request!(setup), original, DateTime.utc_now())

    assert {:error, %{code: :duplicate_request, resend_disposition: :terminal_predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
  end

  test "a link naming a later chain node as another request's successor keeps the fence", %{setup: setup, session: session, opts: opts} do
    assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, original)
    assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    previsible_cut!(setup, session, successor)

    # The chain edge original -> successor is replaced by a link from a request
    # outside the chain: the successor holds the derived claim, but the link
    # says another request chained it.
    Repo.delete_all(from(link in RequestClientRetryLink, where: link.successor_request_id == ^successor.id))
    _link = ClientRetry.insert_link!(foreign_request!(setup), successor, DateTime.utc_now())

    assert {:error, %{code: :duplicate_request, resend_disposition: :terminal_predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
  end

  # The rows a direct websocket socket leaves when its client closes before any
  # output reached it: request and generation-zero attempt failed
  # `client_disconnected`, turn interrupted with no `first_visible_output_at`
  # (findings#232 row 232-112).
  defp previsible_cut!(setup, %CodexSession{} = session, %Request{} = request) do
    now = db_now()

    attempt =
      attempt_fixture(request, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "client_disconnected",
        transport: "websocket",
        usage_status: "usage_unknown",
        response_metadata: %{"error_kind" => "client_disconnected"}
      })

    sequence = Repo.one(from turn in CodexTurn, where: turn.codex_session_id == ^session.id, select: coalesce(max(turn.turn_sequence), 0)) + 1

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: sequence,
      transport_kind: "websocket",
      semantic_turn_digest: :crypto.strong_rand_bytes(32),
      status: "interrupted",
      error_code: "client_disconnected",
      final_attempt_id: attempt.id,
      first_visible_output_at: nil,
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: now
    })

    Repo.update!(Ecto.Changeset.change(request, status: "failed", usage_status: "usage_unknown", response_status_code: 499, last_error_code: "client_disconnected", completed_at: now))
  end

  defp expire_retry_window!(%Request{id: id}) do
    expired_at = DateTime.add(db_now(), -31, :second)
    Repo.update_all(from(r in Request, where: r.id == ^id), set: [completed_at: expired_at])
    Repo.update_all(from(a in Attempt, where: a.request_id == ^id), set: [completed_at: expired_at])
    Repo.update_all(from(t in CodexTurn, where: t.request_id == ^id), set: [completed_at: expired_at])
  end

  defp foreign_request!(setup) do
    Repo.insert!(%Request{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      model_id: setup.model.id,
      requested_model: setup.model.exposed_model_id,
      endpoint: @endpoint,
      transport: "websocket",
      status: "succeeded",
      usage_status: "usage_unknown",
      correlation_id: "client-retry-v1:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      admitted_at: db_now(),
      completed_at: db_now(),
      retry_count: 0
    })
  end

  defp insert_session!(setup) do
    now = db_now()

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "turn-claim-chain-#{System.unique_integer([:positive, :monotonic])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    })
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    DateTime.truncate(now, :microsecond)
  end
end
