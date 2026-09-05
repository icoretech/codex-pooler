defmodule CodexPooler.Gateway.Runtime.ClientRetryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.{Context, RouteState}
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV5
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks
  alias CodexPooler.Repo

  test "a claimed successor carries one database-fenced generation-zero dispatch authority" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)

    assert %ClientRetry.DispatchAuthority{} = authority = claim.dispatch_authority

    attrs = %{
      model: setup.model,
      pricing_snapshot: claim.pricing_snapshot,
      upstream_identity: setup.identity,
      response_metadata: %{"source" => "client_retry"}
    }

    assert {:ok, %Attempt{attempt_number: 1, replay_generation: 0} = attempt} =
             Accounting.create_client_retry_dispatch_attempt(
               claim.request,
               setup.assignment,
               authority,
               attrs
             )

    assert {:error, %{code: :client_retry_dispatch_claimed}} =
             Accounting.create_client_retry_dispatch_attempt(
               claim.request,
               setup.assignment,
               authority,
               attrs
             )

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             1

    assert Repo.get!(Attempt, attempt.id).replay_generation == 0
  end

  test "a forged or stale successor carrier creates no attempt" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)

    forged = %{claim.dispatch_authority | predecessor_request_id: Ecto.UUID.generate()}

    assert {:error, %{code: :invalid_client_retry_dispatch_authority}} =
             Accounting.create_client_retry_dispatch_attempt(
               claim.request,
               setup.assignment,
               forged,
               %{model: setup.model, upstream_identity: setup.identity}
             )

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             0
  end

  test "a failed successor without an original observation settles the upstream failure" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)
    predecessor_before = Repo.get!(Accounting.Request, claim.link.predecessor_request_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.get!(CodexSession, claim.codex_turn.codex_session_id)
    |> Ecto.Changeset.change(
      owner_instance_id: "runtime-retry-owner",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 60, :second),
      last_heartbeat_at: now
    )
    |> Repo.update!()

    assert {:ok, attempt} =
             Accounting.create_client_retry_dispatch_attempt(
               claim.request,
               setup.assignment,
               claim.dispatch_authority,
               %{model: setup.model, upstream_identity: setup.identity}
             )

    assert {:ok, materialized} =
             WebsocketRequestCallbacks.materialize(owner_request!(setup, claim, attempt), nil)

    assert materialized.native_client_retry_observation == nil

    request_options = RequestOptions.for_websocket(%{request_id: "failed-successor"})

    route_plan =
      BridgeRing.plan_route(%{
        auth: setup.auth,
        model: setup.model,
        candidates: [{setup.assignment, setup.identity}],
        route_plan_input: RoutePlanInput.from_reserved(claim),
        request_options: request_options
      })

    context = %SelectedCandidateContext{
      auth: setup.auth,
      endpoint: "/backend-api/codex/responses",
      payload: %{"model" => setup.model.exposed_model_id},
      model: setup.model,
      reserved: Map.from_struct(claim),
      request_options: request_options,
      route_plan: route_plan,
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: false,
      routing_attempt_metadata: %{},
      route_class: "proxy_websocket",
      attempt: attempt,
      client_retry_dispatch_authority: claim.dispatch_authority,
      started: System.monotonic_time(:millisecond)
    }

    assert {:error, %{status: 502, code: "upstream_request_failed"}} =
             Finalization.finalize_failed_websocket_response(context, %{
               body: "",
               headers: [],
               reason: :upstream_websocket_closed_before_terminal,
               native_client_retry_observation: materialized.native_client_retry_observation,
               started: context.started
             })

    assert %{status: "failed", last_error_code: "upstream_stream_error"} =
             Repo.get!(Accounting.Request, claim.request.id)

    assert %{status: "failed", network_error_code: "upstream_stream_error"} =
             settled = Repo.get!(Attempt, attempt.id)

    refute Map.has_key?(settled.response_metadata, "native_client_retry_observation")

    assert %{status: "failed", error_code: "upstream_stream_error", final_attempt_id: attempt_id} =
             Repo.get!(CodexTurn, claim.codex_turn.id)

    assert attempt_id == attempt.id
    assert settled.attempt_number == 1
    assert settled.replay_generation == 0
    assert Repo.get!(Accounting.Request, predecessor_before.id) == predecessor_before

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             1
  end

  test "the owner node accepts only the current successor request and attempt binding" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)

    assert {:ok, attempt} =
             Accounting.create_client_retry_dispatch_attempt(
               claim.request,
               setup.assignment,
               claim.dispatch_authority,
               %{model: setup.model, upstream_identity: setup.identity}
             )

    owner_request = owner_request!(setup, claim, attempt)

    assert {:ok, materialized} = WebsocketRequestCallbacks.materialize(owner_request, nil)
    assert materialized.request_id == claim.request.id
    assert materialized.attempt_id == attempt.id

    Repo.update!(
      Ecto.Changeset.change(attempt,
        status: "failed",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
    )

    assert {:error, {:invalid_owner_request, {:invalid_field, :client_retry_dispatch_authority}}} =
             WebsocketRequestCallbacks.materialize(owner_request, nil)
  end

  test "normal candidate selection starts the successor attempt once and suppresses fallback" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)

    %{assignment: fallback_assignment, identity: fallback_identity} =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Client retry fallback"
      })

    payload = %{"model" => setup.model.exposed_model_id, "input" => []}
    {:ok, policy} = Access.normalize_api_key_policy(setup.api_key)

    request_options =
      %{
        request_id: "client-retry-dispatch",
        upstream_endpoint: "/backend-api/codex/responses",
        transport: "websocket"
      }
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> RequestOptions.put_routing(
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id,
        api_key_policy: policy
      )

    candidates = [
      {setup.assignment, setup.identity},
      {fallback_assignment, fallback_identity}
    ]

    reserved = Map.from_struct(claim)

    assert {:ok, context} =
             Context.new(%{
               auth: setup.auth,
               endpoint: "/backend-api/codex/responses",
               payload: payload,
               model: setup.model,
               reserved: reserved,
               candidates: candidates,
               request_options: request_options,
               route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates})
             })

    assert :ok =
             ClientRetry.validate_dispatch_authority(
               context.reserved.request,
               context.client_retry_dispatch_authority
             )

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             0

    parent = self()

    assert {:error, %{code: "no_eligible_backend"}} =
             Dispatch.dispatch(context, fn selected ->
               send(parent, {:successor_dispatch, selected.assignment.id, selected.attempt.id})
               {:retry, :synthetic_retry}
             end)

    assert_receive {:successor_dispatch, _assignment_id, attempt_id}
    refute_received {:successor_dispatch, _assignment_id, _attempt_id}

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             1

    assert Repo.get!(Attempt, attempt_id).attempt_number == 1
  end

  test "a pre-attempt reservation failure leaves lineage but no phantom attempt" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)

    assert {:ok, finalized} =
             Accounting.finalize_reservation_failure(claim.request, %{
               response_status_code: 503,
               last_error_code: "no_eligible_backend",
               usage_status: "not_applicable"
             })

    assert finalized.request.status == "failed"

    assert {:error, %{code: :request_already_finalized}} =
             Accounting.create_client_retry_dispatch_attempt(
               claim.request,
               setup.assignment,
               claim.dispatch_authority,
               %{model: setup.model, upstream_identity: setup.identity}
             )

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             0

    assert Repo.get!(CodexPooler.Accounting.RequestClientRetryLink, claim.link.id)
  end

  test "reservation-to-assignment failure releases once with lineage and no send" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)

    assert {:ok, finalized} =
             Accounting.finalize_reservation_failure(claim.request, %{
               response_status_code: 503,
               last_error_code: "no_eligible_backend",
               usage_status: "not_applicable"
             })

    assert finalized.request.status == "failed"

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             0

    assert Repo.aggregate(
             from(entry in CodexPooler.Accounting.LedgerEntry,
               where: entry.request_id == ^claim.request.id and entry.entry_kind == "reservation"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in CodexPooler.Accounting.LedgerEntry,
               where: entry.request_id == ^claim.request.id and entry.entry_kind == "release"
             ),
             :count
           ) == 1

    assert Repo.get!(CodexPooler.Accounting.RequestClientRetryLink, claim.link.id)
  end

  test "attempt-to-send lost caller cannot create, validate, or settle a second authority" do
    setup = accounting_setup(%{price_version: unique_price_version()})
    claim = successor_claim!(setup)

    assert {:ok, attempt} =
             Accounting.create_client_retry_dispatch_attempt(
               claim.request,
               setup.assignment,
               claim.dispatch_authority,
               %{model: setup.model, upstream_identity: setup.identity}
             )

    parent = self()
    release = make_ref()

    stale_actor =
      Task.async(fn ->
        send(parent, {:stale_actor_ready, self()})

        receive do
          {:release_stale_actor, ^release} ->
            {
              Accounting.create_client_retry_dispatch_attempt(
                claim.request,
                setup.assignment,
                claim.dispatch_authority,
                %{model: setup.model, upstream_identity: setup.identity}
              ),
              ClientRetry.validate_dispatch_attempt(
                claim.request.id,
                Ecto.UUID.generate(),
                claim.dispatch_authority
              )
            }
        end
      end)

    assert_receive {:stale_actor_ready, stale_pid}
    send(stale_pid, {:release_stale_actor, release})

    assert {
             {:error, %{code: :client_retry_dispatch_claimed}},
             {:error, :stale_owner}
           } = Task.await(stale_actor, 15_000)

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^claim.request.id), :count) ==
             1

    assert :ok =
             ClientRetry.validate_dispatch_attempt(
               claim.request.id,
               attempt.id,
               claim.dispatch_authority
             )
  end

  defp successor_claim!(setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    witness_digest = :crypto.strong_rand_bytes(32)
    semantic_digest = :crypto.strong_rand_bytes(32)

    witness =
      ClientRetry.original_witness!(witness_digest, setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: predecessor}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        requested_model: setup.model.exposed_model_id,
        correlation_id: Ecto.UUID.generate(),
        native_client_retry_witness: witness
      })

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: "runtime-retry-#{System.unique_integer([:positive, :monotonic])}",
        pool_upstream_assignment_id: setup.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      })

    turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: predecessor.id,
        turn_sequence: 1,
        transport_kind: "websocket",
        semantic_turn_digest: semantic_digest,
        status: "failed",
        error_code: "upstream_stream_error",
        first_visible_output_at: now,
        completed_at: now,
        started_at: now,
        created_at: now,
        updated_at: now
      })

    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(predecessor, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "upstream_stream_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        replay_generation: 0,
        response_metadata: eligible_metadata(now)
      })

    Repo.update!(
      Ecto.Changeset.change(predecessor,
        status: "failed",
        usage_status: "usage_unknown",
        completed_at: now,
        last_error_code: "upstream_stream_error"
      )
    )

    Repo.update!(Ecto.Changeset.change(turn, final_attempt_id: attempt.id))

    {:ok, claim} =
      Accounting.claim_client_retry_successor(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "input" => []},
        %{
          endpoint: "/backend-api/codex/responses",
          requested_model: setup.model.exposed_model_id,
          runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
          codex_session: session,
          semantic_turn_digest: semantic_digest,
          replay_claim_digest: witness_digest,
          reservation_estimate: zero_estimate(),
          now: now
        }
      )

    claim
  end

  defp eligible_metadata(now) do
    %{
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
  end

  defp owner_request!(setup, claim, attempt) do
    {:ok, request} =
      WebsocketOwnerRequestV5.new(%{
        version: 5,
        url: "https://upstream.example.com/backend-api/codex/responses",
        headers: [{"authorization", "synthetic-value"}],
        payload: Jason.encode!(%{"model" => setup.model.exposed_model_id, "input" => []}),
        timeouts: %TimeoutConfig{
          connect_timeout_ms: 1_000,
          pool_timeout_ms: 1_000,
          receive_timeout_ms: 30_000
        },
        mapper: :codex_responses,
        upstream_identity_id: setup.identity.id,
        observation: %{
          request_id: claim.request.id,
          client_request_id: "client-request",
          attempt_id: attempt.id,
          mode: "full"
        },
        reset_probe: nil,
        native_codex_response_control: nil,
        assignment_advertised?: true,
        connection_bound_continuation?: false,
        forward_error_body?: false,
        submission_notification?: false,
        client_retry_dispatch_authority: claim.dispatch_authority
      })

    request
  end

  defp zero_estimate do
    %{
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0,
      estimated_cost_micros: Decimal.new(0),
      strategy: "exact"
    }
  end

  defp unique_price_version,
    do: "runtime-client-retry-#{System.unique_integer([:positive, :monotonic])}"
end
