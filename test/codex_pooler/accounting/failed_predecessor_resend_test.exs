defmodule CodexPooler.Accounting.FailedPredecessorResendTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures, only: [attempt_fixture: 3]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{ClientRetry, Request, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"
  @retry_prefix "codex-request-retry:"

  describe "deterministic failed-predecessor resend claim" do
    test "derives one bounded claim per original claim and predecessor without embedding either" do
      original = request_claim()
      predecessor_id = Ecto.UUID.generate()

      assert {:ok, claim} =
               ClientRetry.deterministic_failed_predecessor_claim(original, predecessor_id)

      assert {:ok, ^claim} =
               ClientRetry.deterministic_failed_predecessor_claim(original, predecessor_id)

      assert String.starts_with?(claim, @retry_prefix)
      assert byte_size(claim) == byte_size(@retry_prefix) + 43
      refute ClientRetry.reserved_successor_claim?(claim)
      refute claim =~ String.slice(original, -24, 24)
      refute claim =~ predecessor_id

      assert {:ok, other_predecessor} =
               ClientRetry.deterministic_failed_predecessor_claim(original, Ecto.UUID.generate())

      assert {:ok, chained} =
               ClientRetry.deterministic_failed_predecessor_claim(claim, predecessor_id)

      assert length(Enum.uniq([claim, other_predecessor, chained])) == 3
    end
  end

  describe "claim_websocket_turn after a terminally failed predecessor" do
    setup do
      setup = accounting_setup()
      session = insert_session!(setup)
      claim = request_claim()

      opts = %{
        endpoint: @endpoint,
        correlation_id: claim,
        codex_session: session,
        request_metadata: %{"request_id" => "resend-#{System.unique_integer([:positive])}"}
      }

      %{setup: setup, session: session, claim: claim, opts: opts}
    end

    test "admits the byte-identical resend as a new request with the derived claim and chains",
         %{setup: setup, session: session, claim: claim, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      fail_predecessor!(setup, session, predecessor, "server_error")

      assert {:ok, %{request: resend, client_resend: %{predecessor_shape: :provider_terminal}}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      {:ok, expected_claim} =
        ClientRetry.deterministic_failed_predecessor_claim(claim, predecessor.id)

      assert resend.id != predecessor.id
      assert resend.correlation_id == expected_claim
      assert resend.status == "accepted"
      assert resend.transport == "websocket"
      assert resend.request_metadata["request_id"] == opts.request_metadata["request_id"]

      assert resend.request_metadata["client_resend"] == %{
               "predecessor_request_id" => predecessor.id,
               "reason" => "failed_predecessor"
             }

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2

      # A resend after the admitted retry also fails derives from the retry.
      fail_predecessor!(setup, session, resend, "server_error")

      assert {:ok, %{request: third}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      {:ok, expected_third} =
        ClientRetry.deterministic_failed_predecessor_claim(expected_claim, resend.id)

      assert third.correlation_id == expected_third
      assert third.request_metadata["client_resend"]["predecessor_request_id"] == resend.id
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 3
    end

    test "keeps the duplicate fence while the predecessor is accepted or in progress",
         %{setup: setup, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      attempt_fixture(predecessor, setup.assignment, %{
        status: "in_progress",
        completed_at: nil,
        transport: "websocket",
        usage_status: "usage_pending"
      })

      Repo.update!(Ecto.Changeset.change(predecessor, status: "in_progress"))

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    end

    test "keeps the duplicate fence for a succeeded predecessor", %{setup: setup, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      now = db_now()

      attempt_fixture(predecessor, setup.assignment, %{
        status: "succeeded",
        completed_at: now,
        transport: "websocket"
      })

      Repo.update!(
        Ecto.Changeset.change(predecessor,
          status: "succeeded",
          usage_status: "usage_known",
          completed_at: now
        )
      )

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    end

    test "keeps the duplicate fence when a failed predecessor still has an in-progress turn",
         %{setup: setup, session: session, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      fail_predecessor!(setup, session, predecessor, "server_error")

      Repo.update_all(from(t in CodexTurn, where: t.request_id == ^predecessor.id),
        set: [status: "in_progress", completed_at: nil]
      )

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    end

    test "keeps the duplicate fence after the retry window",
         %{setup: setup, session: session, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      fail_predecessor!(setup, session, predecessor, "server_error")

      expired_at = DateTime.add(db_now(), -31, :second)

      Repo.update_all(from(r in Request, where: r.id == ^predecessor.id),
        set: [completed_at: expired_at]
      )

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    end

    test "keeps the duplicate fence for an owner drain or client disconnect and admits a task exception",
         %{setup: setup, session: session, opts: opts} do
      for code <- ["owner_drained", "client_disconnected", "invalid_request_error"] do
        opts = %{opts | correlation_id: request_claim()}

        {:ok, %{request: predecessor}} =
          Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

        fail_predecessor!(setup, session, predecessor, code)

        assert {:error, %{code: :duplicate_request, resend_disposition: :terminal_predecessor}} =
                 Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
      end

      opts = %{opts | correlation_id: request_claim()}

      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      fail_predecessor!(setup, session, predecessor, "owner_task_exception")

      assert {:ok,
              %{
                request: resend,
                client_resend: %{
                  predecessor_request_id: predecessor_id,
                  predecessor_shape: :task_exception
                }
              }} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert predecessor_id == predecessor.id
      assert String.starts_with?(resend.correlation_id, @retry_prefix)
    end

    test "admits an upstream stream error predecessor with verified lifecycle-cut or partial-reasoning evidence",
         %{setup: setup, session: session, opts: opts} do
      for {shape, metadata} <- [
            lifecycle_cut: lifecycle_cut_metadata(),
            partial_reasoning_cut: partial_reasoning_cut_metadata()
          ] do
        opts = %{opts | correlation_id: request_claim()}

        {:ok, %{request: predecessor}} =
          Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

        fail_predecessor!(setup, session, predecessor, "upstream_stream_error",
          response_metadata: metadata
        )

        assert {:ok,
                %{
                  request: resend,
                  client_resend: %{
                    predecessor_request_id: predecessor_id,
                    predecessor_shape: ^shape
                  }
                }} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

        {:ok, expected_claim} =
          ClientRetry.deterministic_failed_predecessor_claim(opts.correlation_id, predecessor.id)

        assert predecessor_id == predecessor.id
        assert resend.correlation_id == expected_claim

        assert resend.request_metadata["client_resend"] == %{
                 "predecessor_request_id" => predecessor.id,
                 "reason" => "failed_predecessor"
               }
      end

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 4
    end

    test "keeps the duplicate fence for an upstream stream error without verified cut evidence",
         %{setup: setup, session: session, opts: opts} do
      non_closed_transport_failure = %{
        "phase" => "receive",
        "termination_source" => "mint_transport_error",
        "exception" => "Mint.TransportError",
        "reason" => "timeout",
        "transport_signal" => "ssl_closed"
      }

      for {label, metadata} <- [
            without_observation:
              Map.delete(lifecycle_cut_metadata(), "native_client_retry_observation"),
            one_completed_output_item:
              put_in(
                lifecycle_cut_metadata(),
                ["native_client_retry_observation", "output_item_done_count"],
                1
              ),
            non_closed_transport_failure:
              Map.put(lifecycle_cut_metadata(), "transport_failure", non_closed_transport_failure),
            visible_without_reasoning:
              put_in(
                partial_reasoning_cut_metadata(),
                ["native_client_retry_observation", "partial_reasoning_seen"],
                false
              )
          ] do
        opts = %{opts | correlation_id: request_claim()}

        {:ok, %{request: predecessor}} =
          Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

        fail_predecessor!(setup, session, predecessor, "upstream_stream_error",
          response_metadata: metadata
        )

        assert {:error, %{code: :duplicate_request, resend_disposition: :terminal_predecessor}} =
                 Accounting.claim_websocket_turn(setup.auth, setup.model, opts),
               "expected #{label} to keep the fence"
      end

      # A replayed attempt carrying lifecycle-cut evidence is not the
      # generation-zero cut the resend repeats.
      opts = %{opts | correlation_id: request_claim()}

      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      %{attempt: attempt} =
        fail_predecessor!(setup, session, predecessor, "upstream_stream_error",
          response_metadata: lifecycle_cut_metadata()
        )

      Repo.update!(Ecto.Changeset.change(attempt, replay_generation: 1))

      assert {:error, %{code: :duplicate_request, resend_disposition: :terminal_predecessor}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 5
    end

    test "keeps the duplicate fence for an anchored resend of a provider failure",
         %{setup: setup, session: session, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      fail_predecessor!(setup, session, predecessor, "server_error")

      assert {:error, %{code: :duplicate_request, resend_disposition: :anchor_unavailable}} =
               Accounting.claim_websocket_turn(
                 setup.auth,
                 setup.model,
                 Map.put(opts, :anchor_present?, true)
               )

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    end

    test "keeps the duplicate fence when the predecessor holds a replay entitlement",
         %{setup: setup, session: session, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      %{turn: turn, attempt: attempt} =
        fail_predecessor!(setup, session, predecessor, "server_error")

      now = db_now()

      %RequestReplayEntitlement{}
      |> RequestReplayEntitlement.changeset(%{
        request_id: predecessor.id,
        codex_turn_id: turn.id,
        eligible_attempt_id: attempt.id,
        api_key_id: setup.api_key.id,
        api_key_runtime_epoch: setup.api_key.runtime_revocation_epoch,
        pool_id: setup.pool.id,
        model_id: setup.model.id,
        model_identifier: setup.model.exposed_model_id,
        semantic_turn_digest: turn.semantic_turn_digest,
        replay_claim_digest: :crypto.strong_rand_bytes(32),
        replay_generation: 1,
        owner_lease_digest: <<1::256>>,
        owner_lease_key_version: "test-v1",
        predecessor_epoch: 1,
        status: "armed",
        armed_at: now,
        expires_at: DateTime.add(now, 30, :second)
      })
      |> Repo.insert!()

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    end

    test "keeps the duplicate fence without a session lock context or for a turn claim",
         %{setup: setup, session: session, opts: opts} do
      {:ok, %{request: predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      fail_predecessor!(setup, session, predecessor, "server_error")

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(
                 setup.auth,
                 setup.model,
                 Map.delete(opts, :codex_session)
               )

      turn_claim =
        "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      turn_opts = %{opts | correlation_id: turn_claim}

      {:ok, %{request: turn_predecessor}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, turn_opts)

      fail_predecessor!(setup, session, turn_predecessor, "server_error")

      assert {:error, %{code: :duplicate_request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, turn_opts)

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
    end
  end

  defp request_claim,
    do: "codex-request:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp insert_session!(setup) do
    now = db_now()

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "resend-#{System.unique_integer([:positive, :monotonic])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    })
  end

  defp fail_predecessor!(setup, session, request, code, opts \\ []) do
    now = db_now()

    response_metadata =
      Keyword.get(opts, :response_metadata, %{
        "stream_terminal_type" => "response.failed",
        "error_kind" => code
      })

    attempt =
      attempt_fixture(request, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: code,
        transport: "websocket",
        usage_status: "usage_unknown",
        response_metadata: response_metadata
      })

    sequence =
      Repo.one(
        from turn in CodexTurn,
          where: turn.codex_session_id == ^session.id,
          select: coalesce(max(turn.turn_sequence), 0)
      ) + 1

    turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: request.id,
        turn_sequence: sequence,
        transport_kind: "websocket",
        semantic_turn_digest: :crypto.strong_rand_bytes(32),
        status: "failed",
        error_code: code,
        final_attempt_id: attempt.id,
        first_visible_output_at: now,
        started_at: now,
        completed_at: now,
        created_at: now,
        updated_at: now
      })

    request =
      Repo.update!(
        Ecto.Changeset.change(request,
          status: "failed",
          usage_status: "usage_unknown",
          response_status_code: 200,
          last_error_code: code,
          completed_at: now
        )
      )

    %{request: request, attempt: attempt, turn: turn}
  end

  # The metadata a lifecycle-only cut persists (findings issue 124): only
  # `response.created` and `response.in_progress` arrived before the TLS
  # connection closed under the receive loop.
  defp lifecycle_cut_metadata do
    %{
      "transport_failure" => %{
        "phase" => "receive",
        "termination_source" => "mint_transport_error",
        "exception" => "Mint.TransportError",
        "reason" => "closed",
        "transport_signal" => "ssl_closed",
        "terminal_seen" => false,
        "terminal_candidate_seen" => false
      },
      "native_client_retry_observation" => %{
        "version" => 1,
        "authority_complete" => true,
        "output_item_done_count" => 0,
        "output_item_done_count_saturated" => false,
        "partial_reasoning_seen" => false,
        "first_visible_at" => nil,
        "terminal_seen" => false,
        "terminal_candidate_seen" => false
      }
    }
  end

  defp partial_reasoning_cut_metadata do
    metadata = lifecycle_cut_metadata()

    observation =
      metadata["native_client_retry_observation"]
      |> Map.put("partial_reasoning_seen", true)
      |> Map.put("first_visible_at", "2026-09-11T09:00:00.123456Z")

    Map.put(metadata, "native_client_retry_observation", observation)
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end
end
