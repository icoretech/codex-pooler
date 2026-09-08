defmodule CodexPooler.Gateway.Transports.CompactionRetryOwnerCompatibilityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.{Access, Accounting, FakeUpstream}
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.Gateway.Payloads.{NativeCodexTurnMetadata, RequestOptions}
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV7
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DirectCleanup

  @moduletag capture_log: true
  @detection_timeout_ms 15_000

  test "a canceled owner hold is reclaimed on the next downstream without duplicate work" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.created",
             %{"type" => "response.created", "response" => %{"id" => "resp_reclaim"}}},
            {"response.output_item.done",
             %{
               "type" => "response.output_item.done",
               "item" => %{
                 "type" => "compaction",
                 "encrypted_content" => "synthetic-reclaimed-compaction"
               }
             }},
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_reclaim", "status" => "completed"}
             }}
          ],
          notify: self(),
          release_ref: release_ref,
          barrier_after: 1,
          done: false
        )
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    assert {:ok, session} = Websocket.start_codex_session(auth)

    owner =
      start_supervised!(
        {WebsocketOwnerSession,
         [
           codex_session_id: session.id,
           owner_instance_id: session.owner_instance_id,
           owner_lease_token: session.owner_lease_token
         ]}
      )

    assert {:ok, first_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: self(),
               correlation_id: "reclaim-first"
             })

    body = payload(setup)
    first_options = local_options(session, body, first_downstream, auth)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(body, first_options, fn _ -> :ok end)

    predecessor = failed_predecessor!(setup, auth, session, prepared.request_options)
    prepared = admit_retry!(auth, session, prepared)

    assert {:ok, hold} =
             WebsocketOwnerSession.reserve_compaction_retry_submit(
               owner,
               session.owner_lease_token,
               first_downstream,
               self()
             )

    options = prepared.request_options

    attrs =
      AccountingReservation.attrs(
        auth,
        CodexPooler.JSON.decode!(body),
        "/backend-api/codex/responses/compact",
        options
      )
      |> Map.merge(%{
        codex_session: session,
        semantic_turn_digest: options.continuity.semantic_turn_key,
        original_request_claim: options.continuity.request_claim_key,
        replay_claim_digest: options.continuity.replay_claim_digest,
        full_history?: true,
        anchor_present?: false,
        compaction_trigger_bridge?: true,
        owner_idle_validated?: true,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id
      })

    assert {:ok, first} =
             Accounting.claim_compaction_retry_successor(auth, setup.model, %{}, attrs)

    before = counts()
    assert before.attempts == 1
    assert FakeUpstream.count(upstream) == 0
    assert :ok = WebsocketOwnerSession.cancel_compaction_retry_submit(hold)
    assert :ok = WebsocketOwnerSession.detach_downstream(owner, first_downstream)

    assert {:ok, second_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: self(),
               correlation_id: "reclaim-second"
             })

    assert second_downstream.epoch > first_downstream.epoch

    assert {:ok, retry} =
             Service.prepare_websocket_response(
               body,
               local_options(session, body, second_downstream, auth),
               fn _ -> :ok end
             )

    retry = admit_retry!(auth, session, retry)
    task = Task.async(fn -> Service.execute_prepared_websocket_response(auth, retry, true) end)

    assert_receive {:fake_upstream_chunk_barrier, 1, barrier_pid, ^release_ref},
                   @detection_timeout_ms

    current = Repo.get!(Request, first.request.id)
    assert current.status == "in_progress"

    assert current.request_metadata["websocket_owner_forwarding"]["downstream_epoch"] ==
             second_downstream.epoch

    assert Repo.all(RequestClientRetryLink) == [first.link]
    assert Repo.get!(CodexTurn, first.codex_turn.id).status == "in_progress"
    assert Repo.aggregate(Request, :count) == before.requests
    assert Repo.aggregate(Attempt, :count) == before.attempts + 1

    assert {:error, %{code: :invalid_client_retry_dispatch_authority}} =
             Accounting.create_client_retry_dispatch_attempt(
               first.request,
               setup.assignment,
               first.dispatch_authority
             )

    assert Repo.aggregate(Attempt, :count) == before.attempts + 1

    assert Repo.all(
             from entry in LedgerEntry,
               where: entry.request_id == ^first.request.id and entry.entry_kind == "reservation"
           ) == [first.reservation]

    assert :ok =
             DirectCleanup.interrupt(
               %{
                 session_id: session.id,
                 request_id: first.request.id,
                 correlation_id: first.correlation_id,
                 api_key_id: auth.api_key.id,
                 owner_binding: %{
                   owner_instance_id: session.owner_instance_id,
                   owner_lease_token: session.owner_lease_token,
                   downstream_epoch: first_downstream.epoch
                 }
               },
               "client_disconnected"
             )

    assert Repo.get!(Request, first.request.id).status == "in_progress"
    send(barrier_pid, {:fake_upstream_release_chunk, release_ref})
    assert {:ok, %{status: 200}} = Task.await(task, @detection_timeout_ms)
    assert Repo.get!(Request, first.request.id).status == "succeeded"
    assert Repo.get!(CodexTurn, first.codex_turn.id).status == "succeeded"
    assert Repo.get!(Request, predecessor.id).status == "failed"
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    assert Repo.aggregate(RequestClientRetryLink, :count) == 1
    assert :ok = stop_supervised(WebsocketOwnerSession)
  end

  defp local_options(session, body, downstream, auth) do
    assert {:ok, metadata} =
             NativeCodexTurnMetadata.parse(CodexPooler.JSON.decode!(body), session.id)

    Websocket.websocket_owner_response_options(
      %{},
      session,
      session.owner_lease_token,
      downstream
    )
    |> RequestOptions.put_payload_context(native_codex_turn_metadata: metadata)
    |> RequestOptions.capture_api_key_runtime_epoch(auth)
  end

  defmodule OldOwner do
    def connected_app_nodes, do: [:"owner@app.example"]
    def app_node?(_node), do: true

    def call_owner(_node, module, function, args, _timeout) do
      send(self(), {:old_owner_rpc, function})
      {:error, {:exception, :undef, [{module, function, args, []}]}}
    end
  end

  defmodule CompatibleOwner do
    def connected_app_nodes, do: [:"owner@app.example"]
    def app_node?(_node), do: true

    def call_owner(_node, _module, :remote_reserve_compaction_retry_v7, _args, _timeout) do
      hold = CompactionRetrySubmitHold.new()
      send(self(), {:compatible_owner_hold, hold})
      {:ok, hold}
    end

    def call_owner(_node, _module, :remote_submit_request_v7, args, _timeout) do
      send(self(), {:compatible_owner_submission, args})
      {:websocket_owner_submission_accepted, {:error, :owner_drained}}
    end

    def call_owner(_node, _module, :remote_prepare_next_replay_descriptor, _args, _timeout),
      do: :ok

    def call_owner(_node, _module, function, _args, _timeout) do
      send(self(), {:unexpected_owner_rpc, function})
      {:error, :owner_unavailable}
    end
  end

  defmodule PreflightOnlyOwner do
    def connected_app_nodes, do: [:"owner@app.example"]
    def app_node?(_node), do: true

    def call_owner(_node, _module, :remote_preflight_compaction_retry_v7, _args, _timeout) do
      send(self(), :changed_owner_preflight)
      :ok
    end

    def call_owner(_node, module, :remote_reserve_compaction_retry_v7 = function, args, _timeout) do
      send(self(), :changed_owner_reservation_rejected)
      {:error, {:exception, :undef, [{module, function, args, []}]}}
    end

    def call_owner(_node, _module, :remote_prepare_next_replay_descriptor, _args, _timeout),
      do: :ok

    def call_owner(_node, _module, function, _args, _timeout) do
      send(self(), {:unexpected_owner_rpc, function})
      {:error, :owner_unavailable}
    end
  end

  test "an incompatible owner leaves the full-history retry available to a compatible owner" do
    upstream = start_upstream(FakeUpstream.websocket_sse_then_close([]))
    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, session} =
             Websocket.start_codex_session(auth, %{owner_instance_id: "owner@app.example"})

    payload = payload(setup)

    options =
      options(session, payload, OldOwner) |> RequestOptions.capture_api_key_runtime_epoch(auth)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(payload, options, fn _ -> :ok end)

    predecessor = failed_predecessor!(setup, auth, session, prepared.request_options)
    prepared = admit_retry!(auth, session, prepared)
    before = counts()

    assert {:error, error} = Service.execute_prepared_websocket_response(auth, prepared, true)
    assert error.code == "owner_unavailable"
    assert error.status == 503
    assert_received {:old_owner_rpc, :remote_reserve_compaction_retry_v7}
    refute_received {:old_owner_rpc, :remote_submit_request_v7}
    assert counts() == before
    assert FakeUpstream.count(upstream) == 0

    assert {:ok, compatible} =
             Service.prepare_websocket_response(
               payload,
               options(session, payload, CompatibleOwner)
               |> RequestOptions.capture_api_key_runtime_epoch(auth),
               fn _ -> :ok end
             )

    assert {:error, transport_error} =
             Service.execute_prepared_websocket_response(
               auth,
               admit_retry!(auth, session, compatible),
               true
             )

    refute_received {:unexpected_owner_rpc, _function}
    assert transport_error.code == "owner_drained"

    assert_received {:compatible_owner_hold, hold}

    assert_received {:compatible_owner_submission,
                     [_session_id, _downstream, %WebsocketOwnerRequestV7{} = envelope]}

    assert envelope.compaction_retry_submit_hold == hold

    assert [link] = Repo.all(RequestClientRetryLink)
    assert link.predecessor_request_id == predecessor.id
    assert link.successor_request_id == envelope.observation.request_id
    assert Repo.aggregate(Request, :count) == before.requests + 1
    assert Repo.aggregate(Attempt, :count) == before.attempts + 1
    assert Repo.aggregate(CodexTurn, :count) == before.turns + 1
    assert Repo.get!(Request, predecessor.id).status == "failed"

    after_acceptance = counts()

    assert {:ok, duplicate} =
             Service.prepare_websocket_response(
               payload,
               options(session, payload, CompatibleOwner)
               |> RequestOptions.capture_api_key_runtime_epoch(auth),
               fn _ -> :ok end
             )

    assert {:error, %{code: "duplicate_turn"}} =
             Service.prepare_replay_intent(auth, duplicate)

    assert counts() == after_acceptance
    refute_received {:compatible_owner_submission, _args}
  end

  test "a preflight-only owner cannot consume a compaction retry without reserving a submit hold" do
    upstream = start_upstream(FakeUpstream.websocket_sse_then_close([]))
    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, session} =
             Websocket.start_codex_session(auth, %{owner_instance_id: "owner@app.example"})

    payload = payload(setup)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(
               payload,
               options(session, payload, PreflightOnlyOwner)
               |> RequestOptions.capture_api_key_runtime_epoch(auth),
               fn _ -> :ok end
             )

    predecessor = failed_predecessor!(setup, auth, session, prepared.request_options)
    prepared = admit_retry!(auth, session, prepared)
    before = counts()

    assert {:error, error} = Service.execute_prepared_websocket_response(auth, prepared, true)
    assert error.code == "owner_unavailable"
    refute_received :changed_owner_preflight
    assert_received :changed_owner_reservation_rejected
    refute_received {:unexpected_owner_rpc, _function}
    assert FakeUpstream.count(upstream) == 0
    assert counts() == before

    assert {:ok, compatible} =
             Service.prepare_websocket_response(
               payload,
               options(session, payload, CompatibleOwner)
               |> RequestOptions.capture_api_key_runtime_epoch(auth),
               fn _ -> :ok end
             )

    assert {:error, transport_error} =
             Service.execute_prepared_websocket_response(
               auth,
               admit_retry!(auth, session, compatible),
               true
             )

    assert transport_error.code == "owner_drained"
    assert_received {:compatible_owner_hold, hold}

    assert_received {:compatible_owner_submission,
                     [_session_id, _downstream, %WebsocketOwnerRequestV7{} = envelope]}

    assert envelope.compaction_retry_submit_hold == hold
    assert [link] = Repo.all(RequestClientRetryLink)
    assert link.predecessor_request_id == predecessor.id
  end

  defp admit_retry!(auth, session, prepared) do
    assert {:ok, %{intent: :fresh} = intent} = Service.prepare_replay_intent(auth, prepared)

    lifecycle =
      Map.merge(intent.lifecycle || %{replay_generation: 0}, %{
        owner_idle_validated?: true,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id
      })

    assert {:ok, admitted} =
             WebsocketCodec.attach_replay_intent(
               prepared,
               intent.authorization_binding,
               lifecycle
             )

    admitted
  end

  defp failed_predecessor!(setup, auth, session, options) do
    now = DateTime.utc_now()

    assert {:ok, %{request: request}} =
             Accounting.claim_websocket_turn(auth, setup.model, %{
               endpoint: "/backend-api/codex/responses/compact",
               correlation_id: options.continuity.request_claim_key
             })

    request =
      request
      |> Ecto.Changeset.change(
        status: "failed",
        completed_at: now,
        last_error_code: "client_disconnected"
      )
      |> Repo.update!()

    attempt =
      attempt_fixture(request, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "client_disconnected",
        transport: "websocket",
        replay_generation: 0
      })

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      semantic_turn_digest: options.continuity.semantic_turn_key,
      status: "interrupted",
      error_code: "client_disconnected",
      final_attempt_id: attempt.id,
      completed_at: now,
      started_at: now,
      created_at: now,
      updated_at: now
    })

    request
  end

  defp options(session, payload, client) do
    assert {:ok, metadata} =
             NativeCodexTurnMetadata.parse(CodexPooler.JSON.decode!(payload), session.id)

    Websocket.websocket_owner_response_options(
      %{
        websocket_owner_forwarder_opts: [
          node_client: client,
          app_node_names: ["owner@app.example"]
        ]
      },
      session,
      session.owner_lease_token,
      %{pid: self(), epoch: 1, correlation_id: "compatibility"}
    )
    |> RequestOptions.put_payload_context(native_codex_turn_metadata: metadata)
  end

  defp counts do
    %{
      requests: Repo.aggregate(Request, :count),
      links: Repo.aggregate(RequestClientRetryLink, :count),
      attempts: Repo.aggregate(Attempt, :count),
      ledger: Repo.aggregate(LedgerEntry, :count),
      turns: Repo.aggregate(CodexTurn, :count)
    }
  end

  defp payload(setup) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "synthetic"},
        %{"type" => "compaction_trigger"}
      ],
      "stream" => true,
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "turn_id" => Ecto.UUID.generate(),
            "window_id" => Ecto.UUID.generate(),
            "context_window_id" => Ecto.UUID.generate(),
            "window_number" => 1,
            "request_kind" => "compaction",
            "compaction" => %{
              "trigger" => "auto",
              "reason" => "context_limit",
              "implementation" => "responses_compaction_v2",
              "phase" => "pre_turn",
              "strategy" => "memento"
            }
          })
      }
    })
  end
end
