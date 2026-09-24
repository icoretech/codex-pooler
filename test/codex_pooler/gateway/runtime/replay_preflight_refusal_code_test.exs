defmodule CodexPooler.Gateway.Runtime.ReplayPreflightRefusalCodeTest do
  # The runtime replay preflight refuses some frames before it has matched them
  # to any recorded turn: the session binding, the Pool binding and the replay
  # context are checked first. Those refusals apply to a brand-new turn exactly
  # as to a resend, so none of them may answer `409 duplicate_turn` or count as
  # one. Each gets the code the same condition gets on the ordinary path
  # (findings#225, row 225-83).
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import ExUnit.CaptureLog

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.DuplicateTurnTelemetry
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.PoolerFixtures
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  # The matrix states the public outcome per refusal; every case below derives
  # its expectation from it, so the matrix cannot drift from the behaviour.
  @outcomes CompatibilityMatrix.fixture!(:websocket_turn).active_reconnect.runtime_replay_pre_classification

  setup do
    attach_duplicate_turn_counter!()
    setup = accounting_setup()
    %{setup: setup, session: insert_session!(setup)}
  end

  test "a closed session answers owner_unavailable, the code of the owner-lease path for the same state", %{setup: setup, session: session} do
    prepared = prepare(new_turn_payload(setup), session, setup)
    close_session!(session)

    {result, log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, prepared) end)

    assert_outcome(result, :session_not_reconnectable, setup)
    assert log =~ "stage=runtime_replay_preflight reason_code=session_not_reconnectable"
    assert log =~ "public_code=owner_unavailable"
    refute_received {:duplicate_turn_refused, _stage, _transport}
  end

  test "a session bound to another key answers owner_unavailable, not duplicate_turn", %{setup: setup, session: session} do
    other_key = PoolerFixtures.active_api_key_fixture(setup.pool)
    prepared = prepare(new_turn_payload(setup), session, setup)
    Repo.update_all(from(row in CodexSession, where: row.id == ^session.id), set: [api_key_id: other_key.api_key.id])

    {result, log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, prepared) end)

    assert_outcome(result, :session_binding_mismatch, setup)
    assert log =~ "reason_code=session_binding_mismatch"
    refute_received {:duplicate_turn_refused, _stage, _transport}
  end

  test "a key now bound to another Pool answers owner_unavailable, not duplicate_turn", %{setup: setup, session: session} do
    other_pool = PoolerFixtures.pool_fixture()
    prepared = prepare(new_turn_payload(setup), session, setup)
    # A Pool move through the product advances the runtime epoch and is refused
    # as a stale authorization before this check; only a row changed without
    # that advance reaches it, which is what this update simulates.
    Repo.update_all(from(row in APIKey, where: row.id == ^setup.api_key.id), set: [pool_id: other_pool.id])

    {result, log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, prepared) end)

    assert_outcome(result, :session_pool_mismatch, setup)
    assert log =~ "reason_code=session_pool_mismatch"
    refute_received {:duplicate_turn_refused, _stage, _transport}
  end

  test "a Pool disabled after the authorization read is the runtime pool_inactive refusal carrying the key epoch", %{setup: setup, session: session} do
    prepared = prepare(new_turn_payload(setup), session, setup)
    pool_id = setup.pool.id

    # The authorization read already refuses an inactive Pool; the Pool reload
    # only sees one disabled after that read, inside the same transaction.
    Process.put({Service, :replay_pool_hook}, fn ->
      Repo.update_all(from(row in Pool, where: row.id == ^pool_id), set: [status: "disabled"])
    end)

    {result, log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, prepared) end)
    Process.delete({Service, :replay_pool_hook})

    assert_outcome(result, :pool_inactive, setup)
    assert log =~ "reason_code=pool_inactive"
    refute_received {:duplicate_turn_refused, _stage, _transport}
  end

  test "a frame whose replay context cannot be built is a gateway invariant breach, not a duplicate", %{setup: setup, session: session} do
    prepared = prepare(new_turn_payload(setup), session, setup, runtime_epoch?: false)

    {result, log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, prepared) end)

    assert_outcome(result, :invalid_replay_context, setup)
    assert log =~ "reason_code=invalid_replay_context"
    refute_received {:duplicate_turn_refused, _stage, _transport}
  end

  test "control: a resend of a recorded turn is still a counted duplicate_turn at the same stage", %{setup: setup, session: session} do
    payload = new_turn_payload(setup)
    first = prepare(payload, session, setup)

    {:ok, %{request: request}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: first.turn_claim_key,
        native_client_retry_witness: ClientRetry.original_witness!(first.replay_claim_digest, setup.api_key.runtime_revocation_epoch)
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.update!(Ecto.Changeset.change(request, status: "succeeded", completed_at: now))

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      status: "succeeded",
      semantic_turn_digest: first.semantic_turn_key,
      completed_at: now,
      started_at: now,
      created_at: now,
      updated_at: now
    })

    resend = prepare(payload, session, setup)

    {result, log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, resend) end)

    assert {:error, %{status: 409, code: "duplicate_turn"}} = result
    assert log =~ "stage=runtime_replay_preflight"
    assert_received {:duplicate_turn_refused, "runtime_replay_preflight", "websocket"}
  end

  # A model the key may not use refuses a brand-new turn here too; it is
  # recorded once the preflight has rolled back, and logged on the refusal
  # line (S18, 2026-09-24: no row and no line with owner forwarding on). The
  # queued-frame dequeue submits the frame to the ordinary checks after any
  # refusal, which record it, so it asks for no record here.
  # This setup's model is in the Pool's catalog but no assignment serves it
  # (it has no source assignment), so HTTP and the fresh path refuse it
  # `invalid_model` before they read the key's policy, and so does the
  # preflight (findings#206 row 206-549). The served model the key may not
  # use (`model_not_allowed`) is pinned through the socket in
  # `replay_preflight_policy_denial_record_test.exs`.
  test "a listed but unserved model the key may not use is refused invalid_model as HTTP refuses it, recorded and logged, and not counted as a duplicate", %{setup: setup, session: session} do
    forbid_model!(setup)
    prepared = prepare(new_turn_payload(setup), session, setup)

    {result, log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, prepared) end)

    assert {:error, %{status: 400, code: "invalid_model", param: "model"}} = result
    assert [{"rejected", "invalid_model", 400, "websocket", nil}] = refused_rows(setup)
    assert log =~ "stage=runtime_replay_preflight reason_code=invalid_model"
    assert log =~ "public_code=invalid_model"
    refute_received {:duplicate_turn_refused, _stage, _transport}
  end

  test "asked for no record, the same refusal leaves the record to the ordinary checks", %{setup: setup, session: session} do
    forbid_model!(setup)
    prepared = prepare(new_turn_payload(setup), session, setup)

    {result, _log} = with_info_log(fn -> Service.prepare_replay_intent(setup.auth, prepared, record_model_denial: false) end)

    assert {:error, %{status: 400, code: "invalid_model", param: "model"}} = result
    assert refused_rows(setup) == []
  end

  defp forbid_model!(setup) do
    setup.api_key |> Ecto.Changeset.change(allowed_model_identifiers: ["another-model-fixture"]) |> Repo.update!()
    :ok
  end

  defp refused_rows(setup) do
    Repo.all(
      from(request in CodexPooler.Accounting.Request,
        where: request.pool_id == ^setup.pool.id and request.status == "rejected",
        select: {request.status, request.last_error_code, request.response_status_code, request.transport, request.model_id}
      )
    )
  end

  defp assert_outcome(result, reason, setup) do
    refute @outcomes.counted_as_duplicate_turn

    case Map.fetch!(@outcomes, reason) do
      "owner_unavailable" ->
        assert {:error, %{status: 503, code: "owner_unavailable"} = error} = result
        refute Map.has_key?(error, :disabling_epoch)

      "pool_inactive_revocation" ->
        epoch = setup.api_key.runtime_revocation_epoch
        assert {:error, %{status: 401, code: :pool_inactive, disabling_epoch: ^epoch}} = result

      "server_error" ->
        assert {:error, %{status: 500, code: "server_error"}} = result
    end
  end

  defp insert_session!(setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "replay-refusal-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    })
  end

  defp close_session!(session) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.update_all(from(row in CodexSession, where: row.id == ^session.id), set: [status: "closed", closed_at: now])
  end

  defp new_turn_payload(setup) do
    turn_id = "replay-refusal-turn-#{System.unique_integer([:positive])}"

    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"role" => "user", "content" => "synthetic"}],
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "turn_id" => turn_id,
            "request_kind" => "turn",
            "window_id" => "synthetic-window",
            "window_number" => 1,
            "context_window_id" => Ecto.UUID.generate()
          })
      }
    }
  end

  defp prepare(payload, session, setup, opts \\ []) do
    options =
      RequestOptions.build(
        %{codex_session: session, transport: "websocket"},
        "/backend-api/codex/responses",
        payload
      )

    options =
      if Keyword.get(opts, :runtime_epoch?, true),
        do: RequestOptions.put_runtime_context(options, api_key_runtime_epoch: setup.api_key.runtime_revocation_epoch),
        else: options

    {:ok, prepared} = WebsocketCodec.prepare_frame(CodexPooler.JSON.encode!(payload), options, fn _ -> :ok end)
    prepared
  end

  defp with_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)
    parent = self()

    log =
      try do
        capture_log([level: :info], fn -> send(parent, {:replay_refusal_result, fun.()}) end)
      after
        Logger.configure(level: previous)
      end

    assert_received {:replay_refusal_result, result}
    {result, log}
  end

  defp attach_duplicate_turn_counter! do
    test_pid = self()
    handler_id = "replay-preflight-refusal-code-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        DuplicateTurnTelemetry.event(),
        fn _event, %{count: 1}, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:duplicate_turn_refused, metadata.stage, metadata.transport})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
