defmodule CodexPooler.Accounting.ClientRetryTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    Request,
    RequestClientRetryLink,
    RequestReplayEntitlement
  }

  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport

  describe "original witness persistence" do
    test "persists only the trusted typed digest and authenticated epoch on websocket claim" do
      setup = accounting_setup()
      digest = :crypto.strong_rand_bytes(32)
      witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)

      assert {:ok, %{request: request}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: "/backend-api/codex/responses",
                 correlation_id: Ecto.UUID.generate(),
                 native_client_retry_witness: witness,
                 native_client_retry_version: 99,
                 native_client_retry_digest: :crypto.strong_rand_bytes(32),
                 native_client_retry_auth_epoch: 99
               })

      assert %Request{
               native_client_retry_version: 1,
               native_client_retry_digest: ^digest,
               native_client_retry_auth_epoch: epoch
             } = Repo.reload!(request)

      assert epoch == setup.api_key.runtime_revocation_epoch
    end

    test "legacy, null, and malformed witnesses are ineligible" do
      refute ClientRetry.original_witness_eligible?(%Request{})

      refute ClientRetry.original_witness_eligible?(%Request{
               native_client_retry_version: 1,
               native_client_retry_digest: nil,
               native_client_retry_auth_epoch: 0
             })

      refute ClientRetry.original_witness_eligible?(%Request{
               native_client_retry_version: 1,
               native_client_retry_digest: <<1>>,
               native_client_retry_auth_epoch: 0
             })

      refute ClientRetry.original_witness_eligible?(%Request{
               native_client_retry_version: 2,
               native_client_retry_digest: :crypto.strong_rand_bytes(32),
               native_client_retry_auth_epoch: 0
             })
    end
  end

  describe "version 1 observation" do
    test "records partial reasoning and a complete zero-item failure without raw frame data" do
      first_visible_at = ~U[2026-09-05 05:00:00.123456Z]

      observation =
        ClientRetry.new_observation()
        |> ClientRetry.observe_frame(
          %{
            "type" => "response.reasoning_summary_text.delta",
            "delta" => "private reasoning fragment"
          },
          first_visible_at
        )
        |> ClientRetry.complete_without_terminal()

      assert {:ok, metadata} = ClientRetry.final_observation_metadata(observation)

      assert metadata == %{
               "version" => 1,
               "authority_complete" => true,
               "output_item_done_count" => 0,
               "output_item_done_count_saturated" => false,
               "partial_reasoning_seen" => true,
               "first_visible_at" => "2026-09-05T05:00:00.123456Z",
               "terminal_seen" => false,
               "terminal_candidate_seen" => false
             }

      refute inspect(metadata) =~ "private reasoning fragment"
    end

    test "counts completed items with saturation and terminal events close authority" do
      observation =
        %{ClientRetry.new_observation() | output_item_done_count: 65_535}
        |> ClientRetry.observe_frame(
          %{"type" => "response.output_item.done", "item" => %{"type" => "message"}},
          ~U[2026-09-05 05:00:00Z]
        )
        |> ClientRetry.observe_frame(
          %{"type" => "response.completed", "response" => %{}},
          ~U[2026-09-05 05:00:01Z]
        )
        |> ClientRetry.complete_without_terminal()

      assert {:ok, metadata} = ClientRetry.final_observation_metadata(observation)
      assert metadata["output_item_done_count"] == 65_535
      assert metadata["output_item_done_count_saturated"] == true
      assert metadata["terminal_seen"] == true
      assert metadata["terminal_candidate_seen"] == true
    end

    test "unknown executable output poisons observation authority" do
      observation =
        ClientRetry.new_observation()
        |> ClientRetry.observe_frame(
          %{
            "type" => "response.output_item.done",
            "item" => %{"type" => "future_device_call", "call_id" => "private-call-id"}
          },
          ~U[2026-09-05 05:00:00Z]
        )
        |> ClientRetry.complete_without_terminal()

      assert :ineligible = ClientRetry.final_observation_metadata(observation)
      refute inspect(observation) =~ "private-call-id"
    end
  end

  describe "lineage persistence" do
    test "atomically claims one deterministic successor lifecycle for an eligible failed turn" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      digest = :crypto.strong_rand_bytes(32)
      semantic_digest = :crypto.strong_rand_bytes(32)

      {session, predecessor, _attempt} =
        eligible_predecessor!(setup, digest, semantic_digest, now)

      payload = %{"model" => setup.model.exposed_model_id, "input" => []}

      opts = successor_opts(setup, session, digest, semantic_digest, now)

      assert {:ok, claim} =
               Accounting.claim_client_retry_successor(setup.auth, setup.model, payload, opts)

      assert claim.predecessor_request_id == predecessor.id
      assert claim.request.status == "in_progress"
      assert claim.codex_turn.status == "in_progress"
      assert claim.reservation.entry_kind == "reservation"
      assert claim.link.successor_request_id == claim.request.id
      assert claim.request.correlation_id == claim.correlation_id
      assert ClientRetry.reserved_successor_claim?(claim.correlation_id)
      refute ClientRetry.original_witness_eligible?(claim.request)
      assert Repo.aggregate(Attempt, :count) == 1

      assert {:error, :successor_claimed} =
               Accounting.claim_client_retry_successor(setup.auth, setup.model, payload, opts)

      assert Repo.aggregate(RequestClientRetryLink, :count) == 1
      assert Repo.aggregate(Request, :count) == 2
      assert Repo.aggregate(CodexTurn, :count) == 2

      Repo.delete!(claim.link)

      assert {:error, :successor_claimed} =
               Accounting.claim_client_retry_successor(setup.auth, setup.model, payload, opts)

      assert Repo.aggregate(RequestClientRetryLink, :count) == 0
      assert Repo.aggregate(Request, :count) == 2
    end

    test "storage failure rolls back the successor request turn reservation and link" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      digest = :crypto.strong_rand_bytes(32)
      semantic_digest = :crypto.strong_rand_bytes(32)

      {session, predecessor, _attempt} =
        eligible_predecessor!(setup, digest, semantic_digest, now)

      counts = lifecycle_counts(predecessor.id)

      opts =
        setup
        |> successor_opts(session, digest, semantic_digest, now)
        |> Map.put(:force_client_retry_storage_failure, true)

      assert {:error, :storage_failure} =
               Accounting.claim_client_retry_successor(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => []},
                 opts
               )

      assert lifecycle_counts(predecessor.id) == counts
      assert Repo.aggregate(RequestClientRetryLink, :count) == 0
    end

    test "PostgreSQL wall clock sampled after locks rejects a claim that expires while held" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      digest = :crypto.strong_rand_bytes(32)
      semantic_digest = :crypto.strong_rand_bytes(32)
      {session, predecessor, attempt} = eligible_predecessor!(setup, digest, semantic_digest, now)
      almost_expired = DateTime.add(now, -29_950, :millisecond)
      turn = Repo.get_by!(CodexTurn, request_id: predecessor.id)

      Repo.update!(Ecto.Changeset.change(predecessor, completed_at: almost_expired))
      Repo.update!(Ecto.Changeset.change(attempt, completed_at: almost_expired))
      Repo.update!(Ecto.Changeset.change(turn, completed_at: almost_expired))

      opts =
        setup
        |> successor_opts(session, digest, semantic_digest, now)
        |> Map.put(:after_locks, fn -> Repo.query!("SELECT pg_sleep(0.1)", []) end)

      assert {:error, :retry_expired} =
               Accounting.claim_client_retry_successor(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => []},
                 opts
               )

      assert Repo.aggregate(RequestClientRetryLink, :count) == 0
    end

    test "rejects a healthy leased owner without an owner-idle proof" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      digest = :crypto.strong_rand_bytes(32)
      semantic_digest = :crypto.strong_rand_bytes(32)

      {session, _predecessor, _attempt} =
        eligible_predecessor!(setup, digest, semantic_digest, now)

      lease_token = Ecto.UUID.generate()

      Repo.insert!(%BridgeOwnerLease{
        codex_session_id: session.id,
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        pool_upstream_assignment_id: setup.assignment.id,
        owner_instance_id: "owner-a",
        lease_token: lease_token,
        status: "active",
        acquired_at: now,
        renewed_at: now,
        expires_at: DateTime.add(now, 30, :second),
        metadata: %{},
        created_at: now,
        updated_at: now
      })

      session =
        session
        |> Ecto.Changeset.change(
          owner_instance_id: "owner-a",
          owner_lease_token: lease_token,
          owner_lease_expires_at: DateTime.add(now, 30, :second),
          last_heartbeat_at: now
        )
        |> Repo.update!()

      opts = successor_opts(setup, session, digest, semantic_digest, now)

      assert {:error, :active_predecessor} =
               Accounting.claim_client_retry_successor(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => []},
                 opts
               )

      proved =
        Map.merge(opts, %{
          owner_idle_validated?: true,
          owner_lease_token: lease_token,
          owner_instance_id: "owner-a"
        })

      assert {:ok, %ClientRetry.SuccessorClaim{}} =
               Accounting.claim_client_retry_successor(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => []},
                 proved
               )
    end

    test "requires exact Mint.TransportError close identity for receive-phase closed signals" do
      for mutation <- [:wrong_source, :wrong_exception, :wrong_reason] do
        setup = accounting_setup(%{price_version: unique_price_version(to_string(mutation))})
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        digest = :crypto.strong_rand_bytes(32)
        semantic_digest = :crypto.strong_rand_bytes(32)

        {session, predecessor, attempt} =
          eligible_predecessor!(setup, digest, semantic_digest, now)

        transport = %{
          "phase" => "receive",
          "termination_source" => "mint_transport_error",
          "exception" => "Mint.TransportError",
          "reason" => "closed",
          "transport_signal" => "tcp_closed"
        }

        transport =
          case mutation do
            :wrong_source -> Map.put(transport, "termination_source", "socket_message")
            :wrong_exception -> Map.put(transport, "exception", "RuntimeError")
            :wrong_reason -> Map.put(transport, "reason", "timeout")
          end

        metadata = Map.put(attempt.response_metadata, "transport_failure", transport)
        Repo.update!(Ecto.Changeset.change(attempt, response_metadata: metadata))
        opts = successor_opts(setup, session, digest, semantic_digest, now)

        assert {:error, :terminal_predecessor} =
                 Accounting.claim_client_retry_successor(
                   setup.auth,
                   setup.model,
                   %{"model" => setup.model.exposed_model_id, "input" => []},
                   opts
                 )

        assert Repo.aggregate(
                 from(link in RequestClientRetryLink,
                   where: link.predecessor_request_id == ^predecessor.id
                 ),
                 :count
               ) == 0
      end

      setup = accounting_setup(%{price_version: unique_price_version("mint-closed-positive")})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      digest = :crypto.strong_rand_bytes(32)
      semantic_digest = :crypto.strong_rand_bytes(32)

      {session, _predecessor, attempt} =
        eligible_predecessor!(setup, digest, semantic_digest, now)

      exact = %{
        "phase" => "receive",
        "termination_source" => "mint_transport_error",
        "exception" => "Mint.TransportError",
        "reason" => "closed",
        "transport_signal" => "ssl_closed"
      }

      Repo.update!(
        Ecto.Changeset.change(attempt,
          response_metadata: Map.put(attempt.response_metadata, "transport_failure", exact)
        )
      )

      assert {:ok, %ClientRetry.SuccessorClaim{}} =
               Accounting.claim_client_retry_successor(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => []},
                 successor_opts(setup, session, digest, semantic_digest, now)
               )
    end

    test "rejects expired, changed, unsafe, entitled, and successor-chain predecessors without effects" do
      expected_reasons = %{
        expired: :retry_expired,
        payload: :payload_mismatch,
        completed_output: :unsafe_completed_output,
        entitlement: :entitlement_present,
        successor: :retry_exhausted,
        missing_witness: :missing_witness,
        active: :active_predecessor,
        success: :terminal_predecessor,
        epoch: :authorization_changed
      }

      for {mutation, expected_reason} <- expected_reasons do
        setup = accounting_setup(%{price_version: unique_price_version(to_string(mutation))})
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        digest = :crypto.strong_rand_bytes(32)
        semantic_digest = :crypto.strong_rand_bytes(32)

        {session, predecessor, attempt} =
          eligible_predecessor!(setup, digest, semantic_digest, now)

        opts = successor_opts(setup, session, digest, semantic_digest, now)

        opts =
          case mutation do
            :expired ->
              predecessor
              |> Ecto.Changeset.change(completed_at: DateTime.add(now, -31, :second))
              |> Repo.update!()

              opts

            :payload ->
              Map.put(opts, :replay_claim_digest, :crypto.strong_rand_bytes(32))

            _other ->
              opts
          end

        case mutation do
          :completed_output ->
            update_in(
              attempt.response_metadata["native_client_retry_observation"],
              fn observation ->
                Map.put(observation, "output_item_done_count", 1)
              end
            )
            |> then(
              &Repo.update!(
                Ecto.Changeset.change(attempt, response_metadata: &1.response_metadata)
              )
            )

          :entitlement ->
            insert_entitlement!(
              setup,
              session,
              predecessor,
              attempt,
              semantic_digest,
              digest,
              now
            )

          :successor ->
            predecessor
            |> Ecto.Changeset.change(correlation_id: "client-retry-v1:retained-successor")
            |> Repo.update!()

          :missing_witness ->
            predecessor
            |> Ecto.Changeset.change(
              native_client_retry_version: nil,
              native_client_retry_digest: nil,
              native_client_retry_auth_epoch: nil
            )
            |> Repo.update!()

          :active ->
            predecessor
            |> Ecto.Changeset.change(status: "in_progress", completed_at: nil)
            |> Repo.update!()

          :success ->
            predecessor
            |> Ecto.Changeset.change(status: "succeeded")
            |> Repo.update!()

          :epoch ->
            setup.api_key
            |> Ecto.Changeset.change(
              runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch + 1
            )
            |> Repo.update!()

          _other ->
            :ok
        end

        counts = {Repo.aggregate(Request, :count), Repo.aggregate(CodexTurn, :count)}

        assert {:error, ^expected_reason} =
                 Accounting.claim_client_retry_successor(
                   setup.auth,
                   setup.model,
                   %{"model" => setup.model.exposed_model_id, "input" => []},
                   opts
                 )

        assert {Repo.aggregate(Request, :count), Repo.aggregate(CodexTurn, :count)} == counts
        assert Repo.aggregate(RequestClientRetryLink, :count) == 0
      end
    end

    test "enforces request snapshot, unique endpoints, self-link, and delete cascades" do
      setup = accounting_setup()
      digest = :crypto.strong_rand_bytes(32)
      witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      predecessor = claim_request!(setup, witness)
      successor = claim_request!(setup, nil)
      session = insert_session!(setup, now)
      insert_turn!(session, predecessor, 1, now)
      insert_turn!(session, successor, 2, now)

      assert {:ok, link} = ClientRetry.create_link(predecessor, successor, now)
      assert link.predecessor_request_id == predecessor.id
      assert link.successor_request_id == successor.id
      refute ClientRetry.original_witness_eligible?(successor)

      other_successor = claim_request!(setup, nil)
      insert_turn!(session, other_successor, 3, now)

      assert {:error, %Ecto.Changeset{}} =
               ClientRetry.create_link(predecessor, other_successor, now)

      assert %{valid?: false, errors: [successor_request_id: {_, _}]} =
               RequestClientRetryLink.changeset(%RequestClientRetryLink{}, %{
                 predecessor_request_id: other_successor.id,
                 successor_request_id: other_successor.id,
                 created_at: now
               })

      assert_constraint_error(
        "request_client_retry_links_distinct_requests_check",
        """
        INSERT INTO request_client_retry_links
          (id, predecessor_request_id, successor_request_id, created_at)
        VALUES ($1, $2, $2, $3)
        """,
        [Ecto.UUID.generate(), other_successor.id, now]
      )

      assert_constraint_error(
        "request_client_retry_links_predecessor_request_id_uq",
        """
        INSERT INTO request_client_retry_links
          (id, predecessor_request_id, successor_request_id, created_at)
        VALUES ($1, $2, $3, $4)
        """,
        [Ecto.UUID.generate(), predecessor.id, other_successor.id, now]
      )

      assert_constraint_error(
        "request_client_retry_links_successor_request_id_uq",
        """
        INSERT INTO request_client_retry_links
          (id, predecessor_request_id, successor_request_id, created_at)
        VALUES ($1, $2, $3, $4)
        """,
        [Ecto.UUID.generate(), other_successor.id, successor.id, now]
      )

      assert_constraint_error(
        "request_client_retry_links_predecessor_request_id_fkey",
        """
        INSERT INTO request_client_retry_links
          (id, predecessor_request_id, successor_request_id, created_at)
        VALUES ($1, $2, $3, $4)
        """,
        [Ecto.UUID.generate(), Ecto.UUID.generate(), other_successor.id, now]
      )

      assert_constraint_error(
        "request_client_retry_links_successor_request_id_fkey",
        """
        INSERT INTO request_client_retry_links
          (id, predecessor_request_id, successor_request_id, created_at)
        VALUES ($1, $2, $3, $4)
        """,
        [Ecto.UUID.generate(), other_successor.id, Ecto.UUID.generate(), now]
      )

      Repo.delete!(predecessor)
      refute Repo.get(RequestClientRetryLink, link.id)
      retained_successor = Repo.get!(Request, successor.id)
      refute ClientRetry.original_witness_eligible?(retained_successor)

      predecessor_two = claim_request!(setup, witness)
      successor_two = claim_request!(setup, nil)
      insert_turn!(session, predecessor_two, 4, now)
      insert_turn!(session, successor_two, 5, now)
      assert {:ok, second_link} = ClientRetry.create_link(predecessor_two, successor_two, now)

      Repo.delete!(successor_two)
      refute Repo.get(RequestClientRetryLink, second_link.id)
      assert Repo.get!(Request, predecessor_two.id)
    end

    test "API key and pool request cascades remove links without leaving counterparts" do
      api_key_setup = accounting_setup(%{price_version: unique_price_version("api-key")})
      {api_link, _predecessor, _successor} = linked_pair!(api_key_setup)

      Repo.delete!(api_key_setup.api_key)
      refute Repo.get(RequestClientRetryLink, api_link.id)

      pool_setup = accounting_setup(%{price_version: unique_price_version("pool")})
      {pool_link, _predecessor, _successor} = linked_pair!(pool_setup)

      Repo.delete!(pool_setup.pool)
      refute Repo.get(RequestClientRetryLink, pool_link.id)
    end

    test "failure finalization persists one sanitized observation and stale generation cannot write" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{transport: "websocket", correlation_id: Ecto.UUID.generate()}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      summary = %{
        "native_client_retry_observation" => %{
          "version" => 1,
          "authority_complete" => true,
          "output_item_done_count" => 0,
          "output_item_done_count_saturated" => false,
          "partial_reasoning_seen" => true,
          "first_visible_at" => "2026-09-05T05:00:00.123456Z",
          "terminal_seen" => false,
          "terminal_candidate_seen" => false,
          "raw_frame" => "private frame"
        }
      }

      assert {:ok, finalized} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 last_error_code: "upstream_stream_error",
                 attempt_metadata: summary
               })

      observation = finalized.attempt.response_metadata["native_client_retry_observation"]
      assert observation["partial_reasoning_seen"] == true
      refute Map.has_key?(observation, "raw_frame")
      refute inspect(observation) =~ "private frame"

      stale = Repo.update!(Ecto.Changeset.change(finalized.attempt, replay_generation: 1))

      assert {:ok, %{stale_generation?: true}} =
               Accounting.finalize_failure(finalized.request, stale, %{
                 attempt_metadata: %{
                   "native_client_retry_observation" =>
                     Map.put(observation, "partial_reasoning_seen", false)
                 }
               })

      assert Repo.get!(Attempt, stale.id).response_metadata == finalized.attempt.response_metadata
    end
  end

  defp claim_request!(setup, witness) do
    attrs = %{
      endpoint: "/backend-api/codex/responses",
      correlation_id: Ecto.UUID.generate()
    }

    attrs = if witness, do: Map.put(attrs, :native_client_retry_witness, witness), else: attrs

    assert {:ok, %{request: request}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, attrs)

    request
  end

  defp insert_session!(setup, now) do
    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "session-#{System.unique_integer([:positive, :monotonic])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    })
  end

  defp insert_turn!(session, request, sequence, now) do
    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: sequence,
      transport_kind: "websocket",
      status: "in_progress",
      started_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp linked_pair!(setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    witness =
      ClientRetry.original_witness!(
        :crypto.strong_rand_bytes(32),
        setup.api_key.runtime_revocation_epoch
      )

    predecessor = claim_request!(setup, witness)
    successor = claim_request!(setup, nil)
    session = insert_session!(setup, now)
    insert_turn!(session, predecessor, 1, now)
    insert_turn!(session, successor, 2, now)
    assert {:ok, link} = ClientRetry.create_link(predecessor, successor, now)
    {link, predecessor, successor}
  end

  defp eligible_predecessor!(setup, digest, semantic_digest, now) do
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)
    predecessor = claim_request!(setup, witness)
    session = insert_session!(setup, now)

    turn =
      insert_turn!(session, predecessor, 1, now)
      |> Ecto.Changeset.change(semantic_turn_digest: semantic_digest)
      |> Repo.update!()

    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(predecessor, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "upstream_stream_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        replay_generation: 0,
        response_metadata: %{
          "transport_failure" => %{
            "phase" => "receive",
            "termination_source" => "peer_close_frame",
            "transport_signal" => "tcp_closed"
          },
          "native_client_retry_observation" => %{
            "version" => 1,
            "authority_complete" => true,
            "output_item_done_count" => 0,
            "output_item_done_count_saturated" => false,
            "partial_reasoning_seen" => true,
            "first_visible_at" => DateTime.to_iso8601(now),
            "terminal_seen" => false,
            "terminal_candidate_seen" => false
          }
        }
      })

    predecessor =
      predecessor
      |> Ecto.Changeset.change(
        status: "failed",
        usage_status: "usage_unknown",
        completed_at: now,
        last_error_code: "upstream_stream_error"
      )
      |> Repo.update!()

    turn
    |> Ecto.Changeset.change(
      status: "failed",
      error_code: "upstream_stream_error",
      first_visible_output_at: now,
      final_attempt_id: attempt.id,
      completed_at: now
    )
    |> Repo.update!()

    {session, predecessor, attempt}
  end

  defp successor_opts(setup, session, digest, semantic_digest, now) do
    %{
      endpoint: "/backend-api/codex/responses",
      requested_model: setup.model.exposed_model_id,
      runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
      codex_session: session,
      semantic_turn_digest: semantic_digest,
      replay_claim_digest: digest,
      reservation_estimate: %{
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        total_tokens: 0,
        estimated_cost_micros: Decimal.new(0),
        strategy: "exact"
      },
      now: now
    }
  end

  defp insert_entitlement!(setup, _session, request, attempt, semantic_digest, digest, now) do
    %RequestReplayEntitlement{}
    |> RequestReplayEntitlement.changeset(%{
      request_id: request.id,
      codex_turn_id: Repo.get_by!(CodexTurn, request_id: request.id).id,
      eligible_attempt_id: attempt.id,
      api_key_id: setup.api_key.id,
      api_key_runtime_epoch: setup.api_key.runtime_revocation_epoch,
      pool_id: setup.pool.id,
      model_id: setup.model.id,
      model_identifier: setup.model.exposed_model_id,
      semantic_turn_digest: semantic_digest,
      replay_claim_digest: digest,
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

  defp lifecycle_counts(predecessor_id) do
    %{
      requests: Repo.aggregate(Request, :count),
      turns: Repo.aggregate(CodexTurn, :count),
      attempts: Repo.aggregate(Attempt, :count),
      predecessor_ledger:
        Repo.aggregate(
          from(entry in CodexPooler.Accounting.LedgerEntry,
            where: entry.request_id == ^predecessor_id
          ),
          :count
        )
    }
  end

  defp unique_price_version(label),
    do: "t7-#{label}-#{System.unique_integer([:positive, :monotonic])}"

  defp assert_constraint_error(constraint, sql, params) do
    savepoint = "client_retry_constraint_#{System.unique_integer([:positive, :monotonic])}"
    Repo.query!("SAVEPOINT #{savepoint}")

    params =
      Enum.map(params, fn
        <<_::288>> = uuid -> Ecto.UUID.dump!(uuid)
        value -> value
      end)

    assert {:error, %Postgrex.Error{postgres: %{code: code, constraint: ^constraint}}} =
             Repo.query(sql, params)

    assert code in [:check_violation, :unique_violation, :foreign_key_violation]
  end
end
