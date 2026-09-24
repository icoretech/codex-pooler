defmodule CodexPooler.Accounting.ClientRetryChainTest do
  # With owner forwarding on, the owner's client-retry preflight admits a
  # resend of a failed turn as that request's one successor
  # (`client-retry-v1:`). When the successor's client leaves before any output
  # and the owner cannot suspend it into a replay, it settles as a pre-visible
  # disconnect with nothing armed, and the released client resends the turn
  # once more. The original's link used to refuse that resend
  # (`successor_claimed`, findings#206 row 206-525). The resend now chains onto
  # the last successor under the turn-claim chain's edge rule (row 206-519):
  # each node carries only the link from the node before it and the link to the
  # successor holding the claim derived for it, each node is a verified
  # retryable shape with no entitlement and nothing live, and only the node the
  # resend chains onto is held to the retry window.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures, only: [attempt_fixture: 3]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request, RequestClientRetryLink, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  setup do
    setup = accounting_setup()
    session = insert_session!(setup)
    digest = :crypto.strong_rand_bytes(32)
    semantic_digest = :crypto.strong_rand_bytes(32)
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)
    assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(setup.auth, setup.model, %{endpoint: @endpoint, correlation_id: Ecto.UUID.generate(), native_client_retry_witness: witness})
    provider_terminal!(setup, session, original, semantic_digest)
    payload = %{"model" => setup.model.exposed_model_id, "input" => []}
    %{setup: setup, session: session, original: original, payload: payload, opts: successor_opts(setup, session, digest, semantic_digest)}
  end

  test "each resend after a successor cut before any output chains onto that successor", ctx do
    chain =
      Enum.reduce(1..3, [ctx.original], fn _step, [predecessor | _earlier] = chain ->
        predecessor_id = predecessor.id
        assert {:ok, %{client_retry_predecessor_request_id: ^predecessor_id}} = preflight(ctx)
        assert {:ok, claim} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
        assert claim.predecessor_request_id == predecessor.id
        assert claim.link.predecessor_request_id == predecessor.id
        assert {:ok, claim.correlation_id} == ClientRetry.deterministic_successor_claim(ctx.original, predecessor.id)
        assert :ok = ClientRetry.validate_dispatch_authority(claim.request, claim.dispatch_authority)

        # One successor per hop: a concurrent resend of the same hop is refused
        # while the successor is live.
        assert {:error, :successor_claimed} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)

        previsible_cut!(ctx.setup, claim.request)
        [claim.request | chain]
      end)

    assert length(Enum.uniq_by(chain, & &1.correlation_id)) == 4
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^ctx.setup.pool.id), :count) == 4
    assert Repo.aggregate(RequestClientRetryLink, :count) == 3
  end

  test "a served successor keeps the fence", ctx do
    successor = claim_and_cut!(ctx)
    serve!(successor)

    assert {:error, :successor_claimed} = preflight(ctx)
    assert {:error, :successor_claimed} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
  end

  test "a successor holding a replay entitlement keeps the fence", ctx do
    successor = claim_and_cut!(ctx)
    insert_entitlement!(ctx, successor)

    assert {:error, :successor_claimed} = preflight(ctx)
  end

  # The foreign request is in every other respect a node the walk would pass:
  # same scope, a turn of this session and user turn, cut before any output.
  test "a successor chained onto a request that does not hold the claim derived for it keeps the fence", ctx do
    successor = claim_and_cut!(ctx)
    foreign = foreign_request!(ctx.setup)
    insert_turn!(ctx.session, foreign, ctx.opts.semantic_turn_digest)
    previsible_cut!(ctx.setup, foreign)
    _link = ClientRetry.insert_link!(successor, foreign, db_now())

    assert {:error, :successor_claimed} = preflight(ctx)
    assert {:error, :successor_claimed} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
  end

  test "a successor that does not hold the claim derived from its predecessor keeps the fence", ctx do
    successor = claim_and_cut!(ctx)
    Repo.update!(Ecto.Changeset.change(successor, correlation_id: "client-retry-v1:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)))

    assert {:error, :successor_claimed} = preflight(ctx)
  end

  test "the retry window binds the successor the resend chains onto, not the original", ctx do
    successor = claim_and_cut!(ctx)
    expire_retry_window!(ctx.original)
    successor_id = successor.id
    assert {:ok, %{client_retry_predecessor_request_id: ^successor_id}} = preflight(ctx)

    expire_retry_window!(successor)
    assert {:error, :retry_expired} = preflight(ctx)
    assert {:error, :retry_expired} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
  end

  # The shape a direct chain leaves after an HTTPS fallback when owner
  # forwarding is then switched on: the newest websocket request of the turn is
  # a turn-claim successor linked from the request before it and to the native
  # HTTP fallback, which records no semantic digest (findings#206 row 206-533).
  # A request that is itself a successor keeps the fence, and the lineage read
  # must not raise on two links.
  test "a request with both a predecessor and a successor link is refused, not raised", ctx do
    successor = foreign_request!(ctx.setup)
    predecessor = foreign_request!(ctx.setup)
    _incoming = ClientRetry.insert_link!(predecessor, ctx.original, db_now())
    _outgoing = ClientRetry.insert_link!(ctx.original, successor, db_now())

    assert {:error, :retry_exhausted} = preflight(ctx)
    assert {:error, :retry_exhausted} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
    assert Repo.aggregate(RequestClientRetryLink, :count) == 2
  end

  # What a native HTTP fallback finds behind the request it steps over
  # (findings#206 row 206-538): nothing, a successor still running, one cut
  # and settled, or one whose replay the owner armed.
  test "the forwarded chain state names a live, settled or armed last successor", ctx do
    assert ClientRetry.forwarded_chain_state(ctx.original) == :none
    assert {:ok, claim} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
    assert ClientRetry.forwarded_chain_state(ctx.original) == :live

    successor = previsible_cut!(ctx.setup, claim.request)
    assert ClientRetry.forwarded_chain_state(ctx.original) == :settled

    insert_entitlement!(ctx, successor)
    successor_id = successor.id
    assert ClientRetry.forwarded_chain_state(ctx.original) == {:armed, successor_id}

    # A turn-claim successor is not the owner's chain.
    assert ClientRetry.forwarded_chain_state(foreign_request!(ctx.setup)) == :none
  end

  # The HTTPS fallback stepped over the original and was served under the claim
  # derived from it: a later forwarded resend of the same request must not be
  # admitted again (findings#206 row 206-538).
  test "a request whose turn-claim successor exists is refused by the owner preflight", ctx do
    {:ok, derived} = ClientRetry.deterministic_failed_predecessor_claim(ctx.original.correlation_id, ctx.original.id)
    Repo.update!(Ecto.Changeset.change(foreign_request!(ctx.setup), correlation_id: derived, transport: "http_sse", status: "succeeded"))

    assert {:error, :successor_claimed} = preflight(ctx)
    assert {:error, :successor_claimed} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
    assert Repo.aggregate(RequestClientRetryLink, :count) == 0
  end

  defp preflight(ctx), do: Accounting.client_retry_preflight_snapshot(ctx.session, ctx.setup.api_key, ctx.setup.model, ctx.opts)

  defp claim_and_cut!(ctx) do
    assert {:ok, claim} = Accounting.claim_client_retry_successor(ctx.setup.auth, ctx.setup.model, ctx.payload, ctx.opts)
    previsible_cut!(ctx.setup, claim.request)
  end

  # The owner's failed suspension: request and generation-zero attempt failed
  # `client_disconnected`, turn interrupted with no `first_visible_output_at`,
  # nothing armed (findings#232 row 232-112).
  defp previsible_cut!(setup, %Request{} = request) do
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

    Repo.update_all(from(t in CodexTurn, where: t.request_id == ^request.id), set: [status: "interrupted", error_code: "client_disconnected", final_attempt_id: attempt.id, first_visible_output_at: nil, completed_at: now])
    Repo.update!(Ecto.Changeset.change(request, status: "failed", usage_status: "usage_unknown", response_status_code: 499, last_error_code: "client_disconnected", completed_at: now))
  end

  defp serve!(%Request{} = request) do
    now = db_now()
    Repo.update_all(from(a in Attempt, where: a.request_id == ^request.id), set: [status: "succeeded", network_error_code: nil])
    attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))
    Repo.update_all(from(t in CodexTurn, where: t.request_id == ^request.id), set: [status: "succeeded", error_code: nil, final_attempt_id: attempt.id, first_visible_output_at: now, completed_at: now])
    Repo.update!(Ecto.Changeset.change(Repo.reload!(request), status: "succeeded", usage_status: "usage_known", response_status_code: 200, last_error_code: nil, completed_at: now))
  end

  defp provider_terminal!(setup, session, request, semantic_digest) do
    now = db_now()

    attempt =
      attempt_fixture(request, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "server_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        response_metadata: %{"error_kind" => "server_error"}
      })

    Repo.update!(Ecto.Changeset.change(request, status: "failed", usage_status: "usage_unknown", response_status_code: 200, completed_at: now, last_error_code: "server_error"))

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      semantic_turn_digest: semantic_digest,
      status: "failed",
      error_code: "server_error",
      final_attempt_id: attempt.id,
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp insert_entitlement!(ctx, request) do
    now = db_now()
    turn = Repo.get_by!(CodexTurn, request_id: request.id)

    %RequestReplayEntitlement{}
    |> RequestReplayEntitlement.changeset(%{
      request_id: request.id,
      codex_turn_id: turn.id,
      eligible_attempt_id: turn.final_attempt_id,
      api_key_id: ctx.setup.api_key.id,
      api_key_runtime_epoch: ctx.setup.api_key.runtime_revocation_epoch,
      pool_id: ctx.setup.pool.id,
      model_id: ctx.setup.model.id,
      model_identifier: ctx.setup.model.exposed_model_id,
      semantic_turn_digest: ctx.opts.semantic_turn_digest,
      replay_claim_digest: ctx.opts.replay_claim_digest,
      replay_generation: 1,
      owner_lease_digest: <<1::256>>,
      owner_lease_key_version: "test-v1",
      predecessor_epoch: 1,
      status: "armed",
      armed_at: now,
      expires_at: DateTime.add(now, 30, :second)
    })
    |> Repo.insert!()
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
      status: "in_progress",
      usage_status: "usage_pending",
      correlation_id: "client-retry-v1:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      admitted_at: db_now(),
      retry_count: 0
    })
  end

  defp insert_turn!(session, request, semantic_digest) do
    now = db_now()
    sequence = Repo.one(from(t in CodexTurn, where: t.codex_session_id == ^session.id, select: coalesce(max(t.turn_sequence), 0))) + 1

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: sequence,
      transport_kind: "websocket",
      semantic_turn_digest: semantic_digest,
      status: "in_progress",
      started_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp successor_opts(setup, session, digest, semantic_digest) do
    %{
      endpoint: @endpoint,
      requested_model: setup.model.exposed_model_id,
      runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
      codex_session: session,
      semantic_turn_digest: semantic_digest,
      replay_claim_digest: digest,
      reservation_estimate: %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, reasoning_tokens: 0, total_tokens: 0, estimated_cost_micros: Decimal.new(0), strategy: "exact"}
    }
  end

  defp insert_session!(setup) do
    now = db_now()

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "client-retry-chain-#{System.unique_integer([:positive, :monotonic])}",
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
