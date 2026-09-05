defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingTest do
  @moduledoc """
  owner lifecycle terminal-state matrix

  This module is the nearest implementation-facing contract for owner-forwarded
  websocket failures. Keep these terminal states stable so later regression
  tests can grep the matrix before changing behavior.

  - `owner_unavailable` during downstream detach: cleanup-only, sanitized
    failure, triggers bounded recovery/interruption when an active turn may
    exist, and does not create a client-visible request by itself.
  - `owner_unavailable` during request/processed forwarding before upstream
    I/O: request and attempt finalize failed, turn finalizes failed, HTTP/status
    503, code `owner_unavailable`. An unresolved `previous_response_id` alias
    is instead a retarget cache miss: it retains the current authenticated
    runtime without an owner-outage error; the unchanged generation guard may
    later reject that continuation with `previous_response_not_found`.
  - `owner_drained` after the rollout deadline: request and attempt failed,
    response status 499, turn interrupted, session interrupted, lease release
    reason `owner_drained`; before that deadline, active turns remain alive.
  - late owner drain after request success: request and attempt remain
    succeeded; turn remains or becomes succeeded; no owner error overwrite.
  - persistence failure during owner exit: sanitized observability event plus
    the same synchronous inline recovery helper to be implemented later; no
    Oban/supervised async recovery and no silent swallow.
  """

  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestClientRetryLink
  alias CodexPooler.Accounting.RequestLifecycle.Reservation
  alias CodexPooler.Accounting.{RequestLogFact, RequestLogs}
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.AgentV2ContractFixture
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalStatus
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Runtime.Service

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    RoutingCircuitState,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  alias CodexPooler.Gateway.Transports.Websocket.{
    ActivityRegistry,
    NativeCompactionAdmission,
    RolloutDrain
  }

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Transports.WebsocketOwnerPreviousReleaseFixture
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias Ecto.Adapters.SQL.Sandbox

  @sentinel "SECRET_SENTINEL_DO_NOT_STORE_123"
  @supported_compression_model "gpt-4o"
  @blocking_owner_receive_timeout_ms 5_000
  @queued_owner_upstream_start_timeout_ms 5_000
  @response_task_stop_timeout_ms 15_000
  @handoff_detection_timeout_ms 15_000
  @epmd_ready_timeout_ms 2_000
  @epmd_ready_poll_ms 10
  @reasoning_denial_message "reasoning effort is not available for this API key"
  @responses_lite_client_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"
  @model_serving_metadata_keys ~w(
    model_serving_mode_configured
    model_serving_mode
    model_serving_mode_source
  )

  @websocket_lifecycle_metadata_keys ~w(
    codex_session_id
    downstream_epoch
    elapsed_ms
    endpoint
    owner_instance_id
    phase
    proxy_instance_id
    reason_class
    request_id
    route_class
    transport
  )

  @websocket_lifecycle_forbidden_terms ~w(
    auth.json
    authorization
    bearer
    cookie
    headers
    idempotency
    payload
    prompt
    upstream_body
    websocket_frame
  )

  defmodule StaleOwnerNodeClient do
    @moduledoc false

    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Persistence.CodexSession
    alias CodexPooler.Repo

    @impl true
    def connected_app_nodes, do: state().nodes

    @impl true
    def app_node?(node), do: node in state().nodes

    @impl true
    def call_owner(_node, _module, _function, [codex_session_id | _args], _timeout) do
      CodexSession
      |> Repo.get!(codex_session_id)
      |> Ecto.Changeset.change(%{owner_lease_token: Ecto.UUID.generate()})
      |> Repo.update!()

      {:error, :owner_unavailable}
    end

    defp state, do: Process.get(__MODULE__, %{nodes: []})
  end

  defmodule TurnBudgetNodeClient do
    @moduledoc false

    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    @key {__MODULE__, :state}

    def configure(node, notify, minimum_timeout_ms) do
      :persistent_term.put(@key, %{
        node: node,
        notify: notify,
        minimum_timeout_ms: minimum_timeout_ms
      })
    end

    def reset, do: :persistent_term.erase(@key)

    @impl true
    def connected_app_nodes, do: [state().node]

    @impl true
    def app_node?(node), do: node == state().node

    @impl true
    def call_owner(_node, module, function, args, timeout) do
      send(state().notify, {:turn_budget_remote_call, function, timeout})

      if function == :remote_submit_request_v1 and timeout <= state().minimum_timeout_ms do
        {:error, :owner_forward_timeout}
      else
        apply(module, function, args)
      end
    end

    defp state, do: :persistent_term.get(@key)
  end

  defmodule ReplayRemoteNodeClient do
    @moduledoc false

    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    @key {__MODULE__, :state}

    def configure(node, notify), do: :persistent_term.put(@key, %{node: node, notify: notify})
    def reset, do: :persistent_term.erase(@key)

    @impl true
    def connected_app_nodes, do: [state().node]

    @impl true
    def app_node?(node), do: node == state().node

    @impl true
    def call_owner(node, module, function, args, _timeout) do
      send(state().notify, {:replay_remote_owner_call, node, function})
      apply(module, function, args)
    end

    defp state, do: :persistent_term.get(@key)
  end

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()
      TurnBudgetNodeClient.reset()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  for order <- [:terminal_first, :result_first] do
    test "completed-only owner arbitration settles once with #{order}" do
      assert_completed_only_arbitration(unquote(order))
    end
  end

  defp assert_completed_only_arbitration(order) do
    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_completed_only_arbitration",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        }
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, socket} = owner_socket(auth, "ws-completed-only-#{order}", "completed-only-#{order}")
    {:ok, owner} = WebsocketOwnerSession.lookup(socket.codex_session.id)
    parent = self()
    barrier = make_ref()

    :sys.install(
      owner,
      {fn debug_state, event, _name ->
         case event do
           {:noreply, %{active_turn: %{pending_result: result, terminal_forwarded?: forwarded}}}
           when not is_nil(result) ->
             send(parent, {:arbitration_pending, barrier, forwarded})

           _ ->
             :ok
         end

         debug_state
       end, nil}
    )

    :sys.replace_state(owner, fn state ->
      real_sender = state.callbacks.upstream_sender

      sender = completed_only_arbitration_sender(real_sender, order, parent, barrier)

      %{state | callbacks: %{state.callbacks | upstream_sender: sender}}
    end)

    {:ok, socket} =
      CodexResponsesSocket.handle_in(
        {websocket_payload(setup, "completed only"), [opcode: :text]},
        socket
      )

    assert_receive {:arbitration_result, ^barrier, sender}, @handoff_detection_timeout_ms

    socket =
      case order do
        :terminal_first ->
          next = receive_completed_only_arbitration_terminal(socket, terminal)

          assert :sys.get_state(owner).active_turn.terminal_forwarded?
          send(sender, {:arbitration_release, barrier})
          next

        :result_first ->
          assert_receive {:arbitration_frame, ^barrier, deliver}, @handoff_detection_timeout_ms
          send(sender, {:arbitration_release, barrier})
          assert_receive {:arbitration_pending, ^barrier, false}, @handoff_detection_timeout_ms
          deliver.()

          receive_completed_only_arbitration_terminal(socket, terminal)
      end

    assert {:ok, socket} = receive_owner_socket_complete(socket)
    socket = drain_completed_only_arbitration(socket)
    assert [request] = request_logs(setup.pool.id)
    assert request.status == "succeeded"
    assert request.response_status_code == 200
    assert_forwarding_cardinality!(request, socket.codex_session.id, "succeeded")
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    refute_received {:websocket_owner_frame, _, _, _, {:data, ^terminal}}
    CodexResponsesSocket.terminate(:closed, socket)
  end

  defp completed_only_arbitration_sender(real_sender, order, parent, barrier) do
    fn upstream_pid, payload, writer ->
      observed_writer = completed_only_arbitration_writer(writer, order, parent, barrier)
      result = real_sender.(upstream_pid, payload, observed_writer)
      send(parent, {:arbitration_result, barrier, self()})

      receive do
        {:arbitration_release, ^barrier} -> result
      after
        @handoff_detection_timeout_ms -> {:error, :barrier_timeout}
      end
    end
  end

  defp completed_only_arbitration_writer(writer, order, parent, barrier) do
    fn frame, discriminator ->
      case {order, TerminalDiscriminator.terminal?(discriminator)} do
        {:terminal_first, _} ->
          writer.(frame, discriminator)

        {:result_first, false} ->
          writer.(frame, discriminator)

        {:result_first, true} ->
          hold_completed_only_arbitration_frame(parent, barrier, writer, frame, discriminator)
      end
    end
  end

  defp hold_completed_only_arbitration_frame(parent, barrier, writer, frame, discriminator) do
    send(parent, {:arbitration_frame, barrier, fn -> writer.(frame, discriminator) end})
  end

  defp receive_completed_only_arbitration_terminal(socket, terminal) do
    assert {:push, {:text, frame}, socket} = receive_owner_socket_raw_push(socket)

    if frame == terminal do
      socket
    else
      assert Jason.decode!(frame)["type"] == "codex.response.metadata"
      receive_completed_only_arbitration_terminal(socket, terminal)
    end
  end

  defp drain_completed_only_arbitration(socket) do
    if MapSet.size(socket.tasks) == 0 do
      socket
    else
      receive do
        {:websocket_response_activity, _, _} = message ->
          assert {:ok, socket} = CodexResponsesSocket.handle_info(message, socket)
          drain_completed_only_arbitration(socket)

        {:codex_response_done, _, result} = message ->
          assert result == {:socket_response_result, :owner_completion_pending, :ok}
          assert {:ok, socket} = CodexResponsesSocket.handle_info(message, socket)
          drain_completed_only_arbitration(socket)

        {:websocket_response_delivery_complete, _, _} = message ->
          assert {:ok, socket} = CodexResponsesSocket.handle_info(message, socket)
          drain_completed_only_arbitration(socket)
      after
        @handoff_detection_timeout_ms -> flunk("expected terminal arbitration task cleanup")
      end
    end
  end

  test "owner-forwarded native anchored compact uses V2 collect on the current connection" do
    final_release_ref = make_ref()

    compact_item = %{
      "type" => "compaction",
      "encrypted_content" => "synthetic-owner-collect-encrypted"
    }

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream([
             {"response.created",
              %{
                "type" => "response.created",
                "response" => %{
                  "id" => "resp_owner_collect_anchor",
                  "status" => "in_progress"
                }
              }},
             {"response.completed",
              %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_owner_collect_anchor",
                  "status" => "completed",
                  "output" => []
                }
              }}
           ]),
           FakeUpstream.sse_stream([
             {"response.output_item.done",
              %{"type" => "response.output_item.done", "item" => compact_item}},
             {"response.completed",
              %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_owner_collect_compact",
                  "status" => "completed",
                  "output" => [compact_item]
                }
              }}
           ]),
           FakeUpstream.barrier_sse_stream(
             [
               {"response.created",
                %{
                  "type" => "response.created",
                  "response" => %{
                    "id" => "resp_owner_collect_final",
                    "status" => "in_progress"
                  }
                }},
               {"response.completed",
                %{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_owner_collect_final",
                    "status" => "completed",
                    "output" => []
                  }
                }}
             ],
             notify: self(),
             release_ref: final_release_ref,
             barrier_after: 0
           )
         ]}
      )

    setup = gateway_setup(upstream, compact?: true)
    scope = model_serving_scope()
    _revision = set_model_serving_mode!(scope, setup, "full")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-native-collect", "owner-native-collect")
    native_turn_id = "owner-native-collect-turn"
    context_window_id = "00000000-0000-4000-8000-000000000505"

    turn_metadata = fn request_kind ->
      base = %{
        "turn_id" => native_turn_id,
        "window_id" => "owner-native-collect-window",
        "context_window_id" => context_window_id,
        "window_number" => 1,
        "request_kind" => request_kind
      }

      if request_kind == "compaction" do
        Map.put(base, "compaction", %{
          "trigger" => "auto",
          "reason" => "context_limit",
          "implementation" => "responses_compaction_v2",
          "phase" => "mid_turn",
          "strategy" => "memento"
        })
      else
        base
      end
      |> Jason.encode!()
    end

    try do
      anchor_payload =
        websocket_payload(setup, "synthetic owner collect anchor", %{
          "request_id" => "ws-owner-native-collect-anchor",
          "client_metadata" => %{
            "turn_id" => native_turn_id,
            "x-codex-turn-metadata" => turn_metadata.("turn")
          }
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, state)

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)

      assert %{"response" => %{"id" => "resp_owner_collect_anchor"}} =
               Jason.decode!(anchor_frame)

      assert {:push, {:text, anchor_terminal_frame}, state} = receive_owner_socket_push(state)
      assert %{"type" => "response.completed"} = Jason.decode!(anchor_terminal_frame)
      assert {:ok, state} = receive_socket_done(state)

      compact_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_owner_collect_anchor",
          "input" => [
            %{
              "type" => "custom_tool_call_output",
              "call_id" => "call_owner_collect",
              "output" => "synthetic owner tool output"
            },
            %{"type" => "compaction_trigger"}
          ],
          "stream" => true,
          "generate" => true,
          "request_id" => "ws-owner-native-collect-compact",
          "client_metadata" => %{
            "turn_id" => native_turn_id,
            "x-codex-turn-metadata" => turn_metadata.("compaction")
          }
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({compact_payload, [opcode: :text]}, state)

      assert {:push, {:text, done_frame}, state} = receive_native_collect_socket_push(state)

      assert %{"type" => "response.output_item.done", "item" => ^compact_item} =
               Jason.decode!(done_frame)

      assert {:push, {:text, completed_frame}, state} = receive_native_collect_socket_push(state)
      assert {:ok, state} = receive_socket_done(state)

      assert %{
               "type" => "response.completed",
               "response" => %{"output" => [^compact_item]}
             } = Jason.decode!(completed_frame)

      assert [anchor_request, compact_request] = FakeUpstream.requests(upstream)
      assert anchor_request.method == "WEBSOCKET"
      assert compact_request.method == "WEBSOCKET"
      assert anchor_request.websocket_connection_id == compact_request.websocket_connection_id
      assert FakeUpstream.http_request_count(upstream) == 0

      assert [anchor_log, compact_log] = request_logs(setup.pool.id)
      assert anchor_log.transport == "websocket"
      assert compact_log.endpoint == "/backend-api/codex/responses/compact"
      assert compact_log.transport == "websocket"
      assert compact_log.retry_count == 0
      assert compact_log.request_metadata["websocket_owner_forwarding"]["enabled"] == true

      assert [compact_attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

      assert compact_attempt.transport == "websocket"
      assert compact_attempt.status == "succeeded"
      assert compact_attempt.response_metadata["upstream_websocket_connection"]["reused"] == true

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^compact_log.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert [compact_turn] =
               Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_log.id))

      assert compact_turn.status == "succeeded"
      assert compact_turn.final_attempt_id == compact_attempt.id

      assert {:ok, owner} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert NativeCompactionAdmission.phase(:sys.get_state(owner).native_compaction_admission) ==
               :pending_final

      final_metadata =
        Jason.encode!(%{
          "turn_id" => native_turn_id,
          "window_id" => "owner-native-collect-final-window",
          "context_window_id" => "00000000-0000-4000-8000-000000000506",
          "window_number" => 2,
          "request_kind" => "turn"
        })

      final_payload =
        websocket_payload(setup, "synthetic owner collect final", %{
          "request_id" => "ws-owner-native-collect-final",
          "client_metadata" => %{
            "turn_id" => native_turn_id,
            "x-codex-turn-metadata" => final_metadata
          },
          "input" => [
            compact_item,
            %{"type" => "message", "role" => "user", "content" => "final"}
          ]
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({final_payload, [opcode: :text]}, state)

      final_upstream_pid =
        receive do
          {:fake_upstream_chunk_barrier, 0, pid, ^final_release_ref} -> pid
        after
          15_000 -> flunk("final request did not reach the pre-visible upstream barrier")
        end

      try do
        window_hash = :crypto.hash(:sha256, "owner-native-collect-final-window")

        alias_present? =
          Repo.exists?(
            from(alias_record in BridgeSessionAlias,
              where:
                alias_record.codex_session_id == ^state.codex_session.id and
                  alias_record.alias_kind == "session_header" and
                  alias_record.alias_hash == ^window_hash and alias_record.status == "active"
            )
          )

        assert alias_present?

        assert {:ok, reconnect_session} =
                 Gateway.start_codex_session(auth,
                   accepted_turn_state: "new-upgrade-generated-turn-state",
                   session_header_source: "x-codex-window-id",
                   session_header: "owner-native-collect-final-window"
                 )

        assert reconnect_session.id == state.codex_session.id
      after
        send(final_upstream_pid, {:fake_upstream_release_chunk, final_release_ref})
      end

      assert {:ok, state} = receive_socket_done(state)

      assert [_anchor_request, compact_request, final_request] = FakeUpstream.requests(upstream)
      assert final_request.method == "WEBSOCKET"
      assert final_request.websocket_connection_id == compact_request.websocket_connection_id
      assert FakeUpstream.http_request_count(upstream) == 0

      assert [anchor_log, compact_log, final_log] = request_logs(setup.pool.id)

      request_ids = [anchor_log.id, compact_log.id, final_log.id]
      correlations = Enum.map([anchor_log, compact_log, final_log], & &1.correlation_id)

      assert length(Enum.uniq(correlations)) == 3
      assert length(request_ids) == 3

      attempts =
        Repo.all(
          from(attempt in Attempt,
            where: attempt.request_id in ^request_ids,
            order_by: [asc: attempt.started_at]
          )
        )

      turns =
        Repo.all(
          from(turn in CodexTurn,
            where:
              turn.codex_session_id == ^state.codex_session.id and turn.request_id in ^request_ids,
            order_by: [asc: turn.turn_sequence]
          )
        )

      ledger_entries =
        Repo.all(
          from(entry in LedgerEntry,
            where: entry.request_id in ^request_ids,
            order_by: [asc: entry.occurred_at]
          )
        )

      assert length(attempts) == 3
      assert Enum.all?(attempts, &(&1.status == "succeeded" and &1.transport == "websocket"))
      assert length(turns) == 3
      assert Enum.all?(turns, &(&1.status == "succeeded" and &1.transport_kind == "websocket"))
      assert Enum.count(ledger_entries, &(&1.entry_kind == "reservation")) == 3
      assert Enum.count(ledger_entries, &(&1.entry_kind == "settlement")) == 3

      connection_metadata =
        Enum.map(attempts, &get_in(&1.response_metadata, ["upstream_websocket_connection"]))

      assert Enum.all?(connection_metadata, &is_map/1)
      assert connection_metadata |> Enum.map(& &1["lifecycle_id"]) |> Enum.uniq() |> length() == 1
      assert connection_metadata |> Enum.map(& &1["generation"]) |> Enum.uniq() == [1]
      assert Enum.count(connection_metadata, &(&1["reused"] == false)) == 1
      assert Enum.count(connection_metadata, &(&1["reused"] == true)) == 2

      assert Enum.all?([anchor_log, compact_log, final_log], fn request ->
               request.retry_count == 0 and request.transport == "websocket"
             end)

      assert FakeUpstream.http_request_count(upstream) == 0

      assert final_log.transport == "websocket"
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :owner_forwarding_catalog_token
  test "owner-forwarding-enabled Mint upgrades keep one catalog token across backend aliases",
       %{conn: conn} do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    models_conn =
      conn
      |> auth(setup)
      |> get("/backend-api/codex/models")

    assert [models_etag] = get_resp_header(models_conn, "etag")
    models_accounting_count = Repo.aggregate(Request, :count)
    port = start_public_endpoint!()

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)

    {local_conn, _websocket, _ref, local_headers} =
      public_websocket_connect_with_headers!(port, setup, "")

    local_token =
      try do
        assert Repo.aggregate(Request, :count) == models_accounting_count
        assert {"x-models-etag", token} = List.keyfind(local_headers, "x-models-etag", 0)
        assert token == models_etag
        token
      after
        Mint.HTTP.close(local_conn)
      end

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    alias_tokens =
      for path <- ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"] do
        {mint_conn, _websocket, _ref, response_headers} =
          public_websocket_connect_with_headers!(port, setup, "", path)

        try do
          assert Application.fetch_env!(:codex_pooler, :websocket_owner_forwarding_enabled)
          assert Repo.aggregate(Request, :count) == models_accounting_count
          assert {"x-models-etag", token} = List.keyfind(response_headers, "x-models-etag", 0)
          assert token == models_etag
          token
        after
          Mint.HTTP.close(mint_conn)
        end
      end

    assert alias_tokens == [local_token, local_token]
    assert Repo.aggregate(Request, :count) == models_accounting_count
  end

  test "owner-forwarded websocket turns reuse one upstream websocket connection" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => "resp_owner_first", "object" => "response"}),
           FakeUpstream.json_response(%{"id" => "resp_owner_second", "object" => "response"})
         ]}
      )

    setup = gateway_setup(upstream)
    residency = "ws-owner-region-#{System.unique_integer([:positive])}"
    access_token = synthetic_access_token(residency)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "access_token",
               plaintext: access_token
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-forwarding",
          accepted_turn_state: "stable-ws-owner-forwarding",
          client_ip: "127.0.0.1"
        }
      })

    try do
      handoff = AgentV2ContractFixture.handoff!(:spawn_agent)
      first_payload = websocket_input_payload(setup, [handoff])

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_first"} = Jason.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      second_payload = websocket_payload(setup, "second")

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_second"} = Jason.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.websocket_connection_count(upstream) == 1
      assert [opaque_connection_id] = FakeUpstream.websocket_connection_ids(upstream)
      assert is_reference(opaque_connection_id)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert first_request.json["input"] == [handoff]

      for captured <- [first_request, second_request] do
        assert header_values(captured.headers, "x-openai-internal-codex-residency") == [
                 residency
               ]

        assert header_values(captured.headers, "chatgpt-account-id") == [
                 setup.identity.chatgpt_account_id
               ]
      end

      assert [first_request_log, second_request_log] =
               Repo.all(
                 from(r in Request,
                   where: r.pool_id == ^setup.pool.id,
                   order_by: [asc: r.admitted_at, asc: r.id]
                 )
               )

      assert first_request_log.transport == "websocket"
      assert second_request_log.transport == "websocket"

      assert [first_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^first_request_log.id))

      assert [second_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^second_request_log.id))

      assert first_attempt.transport == "websocket"
      assert second_attempt.transport == "websocket"

      first_connection = first_attempt.response_metadata["upstream_websocket_connection"]
      second_connection = second_attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id, "generation" => generation} = first_connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)
      assert generation == 1

      assert first_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => generation,
               "reused" => false,
               "reconnected" => false
             }

      assert second_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => generation,
               "reused" => true,
               "reconnected" => false
             }

      for {request_log, attempt} <- [
            {first_request_log, first_attempt},
            {second_request_log, second_attempt}
          ] do
        assert [settlement] =
                 Repo.all(
                   from(entry in LedgerEntry,
                     where:
                       entry.request_id == ^request_log.id and
                         entry.entry_kind == "settlement"
                   )
                 )

        assert settlement.attempt_id == attempt.id
        assert settlement.transport == "websocket"
      end

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("stable-ws-owner-forwarding")
        )

      refute_raw_turn_state_session_key!(setup.pool.id, "stable-ws-owner-forwarding")
      assert session.owner_instance_id == Atom.to_string(node())
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert_owner_websocket_values_not_persisted!(setup, [residency, access_token], "")
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded native failure after accepted data logs visible output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-output-after-data")
    downstream = state.websocket_owner_downstream
    frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "visible"})

    assert {:push, {:text, ^frame}, state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, frame}),
               state
             )

    assert state.native_turn_output_task_pids == MapSet.new([task_pid])

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, error_frame}, failed_state} = result

    assert %{"type" => "error", "error" => %{"code" => "owner_drained"}} =
             Jason.decode!(error_frame)

    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-after-data", "after_visible_output")
  end

  test "owner-forwarded native failure before data logs no visible output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-output-before-data")
    downstream = state.websocket_owner_downstream

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, error_frame}, failed_state} = result

    assert %{"type" => "error", "error" => %{"code" => "owner_drained"}} =
             Jason.decode!(error_frame)

    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-before-data", "before_visible_output")
  end

  test "owner-forwarded metadata-only data remains pre-visible while unknown controls commit output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-metadata-pre-visible")
    downstream = state.websocket_owner_downstream

    metadata_frame =
      Jason.encode!(%{
        "type" => "codex.response.metadata",
        "headers" => %{"x-models-etag" => ~s(W/"owner-turn-etag")}
      })

    assert {:push, {:text, ^metadata_frame}, state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, metadata_frame}),
               state
             )

    assert state.native_turn_output_task_pids == MapSet.new()

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-metadata-pre-visible", "before_visible_output")

    unknown_frame = Jason.encode!(%{"type" => "codex.future_control"})

    assert {:push, {:text, ^unknown_frame}, visible_state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, unknown_frame}),
               state
             )

    assert visible_state.native_turn_output_task_pids == MapSet.new([task_pid])
  end

  test "owner-forwarded native output state resets before a second turn" do
    first_task_pid = socket_test_task()
    second_task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(first_task_pid) end)
    on_exit(fn -> stop_socket_test_task(second_task_pid) end)

    state = owner_output_state(first_task_pid, "ws-owner-output-second-turn")
    downstream = state.websocket_owner_downstream
    frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "first"})

    assert {:push, {:text, ^frame}, state} =
             CodexResponsesSocket.handle_info(
               owner_frame(downstream, {:data, frame}),
               state
             )

    assert {:ok, state} =
             CodexResponsesSocket.handle_info(owner_frame(downstream, :complete), state)

    assert state.native_turn_output_task_pids == MapSet.new()

    state = replace_owner_output_task(state, first_task_pid, second_task_pid)

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-second-turn", "before_visible_output")
  end

  test "owner-forwarded public rate-limit-only data does not commit output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = public_owner_output_state(task_pid, "ws-owner-public-rate-only")
    downstream = state.websocket_owner_downstream

    rate_limit_frame =
      Jason.encode!(%{
        "type" => "codex.rate_limits",
        "rate_limits" => %{"primary" => %{"used_percent" => 42}}
      })

    assert {:push, {:text, normalized_frame}, state} =
             CodexResponsesSocket.handle_info(
               public_owner_frame(downstream, task_pid, {:data, rate_limit_frame}),
               state
             )

    assert %{"type" => "codex.rate_limits"} = Jason.decode!(normalized_frame)
    refute state.public_turn_output_committed?

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          public_owner_frame(
            downstream,
            task_pid,
            owner_error_payload(:upstream_stream_error)
          ),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    refute failed_state.public_turn_output_committed?
    assert_native_owner_turn_log!(logs, "ws-owner-public-rate-only", "before_visible_output")
  end

  test "owner-forwarded public metadata-only data does not commit output" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = public_owner_output_state(task_pid, "ws-owner-public-metadata-only")
    downstream = state.websocket_owner_downstream

    metadata_frame =
      Jason.encode!(%{
        "type" => "codex.response.metadata",
        "headers" => %{"x-models-etag" => ~s(W/"owner-public-etag")}
      })

    assert {:push, {:text, normalized_frame}, state} =
             CodexResponsesSocket.handle_info(
               public_owner_frame(downstream, task_pid, {:data, metadata_frame}),
               state
             )

    assert Jason.decode!(normalized_frame) == %{
             "headers" => %{"x-models-etag" => ~s(W/"owner-public-etag")},
             "sequence_number" => 0,
             "type" => "codex.response.metadata"
           }

    refute state.public_turn_output_committed?
  end

  test "late stale owner epoch data cannot commit the active native turn" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)

    state = owner_output_state(task_pid, "ws-owner-output-stale-epoch", 2)
    active_downstream = state.websocket_owner_downstream
    stale_downstream = %{active_downstream | epoch: 1}
    stale_frame = Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "stale"})

    assert {:ok, ^state} =
             CodexResponsesSocket.handle_info(
               owner_frame(stale_downstream, {:data, stale_frame}),
               state
             )

    {result, logs} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_info(
          owner_frame(active_downstream, owner_error_payload(:owner_drained)),
          state
        )
      end)

    assert {:push, {:text, _error_frame}, failed_state} = result
    assert failed_state.native_turn_output_task_pids == MapSet.new()
    assert_native_owner_turn_log!(logs, "ws-owner-output-stale-epoch", "before_visible_output")
    refute logs =~ "delta=stale"
  end

  test "owner-forwarded websocket reasoning denial cannot bypass pre-dispatch policy" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    setup.api_key
    |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
    |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reasoning-denial", "owner-reasoning-denial")

    try do
      payload =
        websocket_payload(setup, "synthetic owner policy denial", %{"reasoning_effort" => "high"})

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, error_frame}, state} = receive_socket_done(state)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "code" => "reasoning_effort_not_allowed",
                 "message" => @reasoning_denial_message,
                 "param" => "reasoning.effort"
               }
             } = Jason.decode!(error_frame)

      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      assert FakeUpstream.count(upstream) == 0
      assert [request] = request_logs(setup.pool.id)
      assert request.status == "rejected"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) ==
               0

      assert get_in(request.request_metadata, ["gateway_denial", "reasoning_policy"]) == %{
               "policy_mode" => "allow_up_to",
               "configured_effort" => "medium",
               "requested_effort" => "high",
               "applied_effort" => nil
             }
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :f2_owner_terminal_error_param
  test "owner-forwarded terminal failure persists only its safe upstream error param" do
    message_sentinel = "owner-terminal-message-sentinel"
    value_sentinel = "owner-terminal-value-sentinel"
    frame_sentinel = "owner-terminal-frame-sentinel"
    header_sentinel = "owner-terminal-header-sentinel"
    token_sentinel = "owner-terminal-token-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "raw_frame" => frame_sentinel,
               "response" => %{
                 "id" => "resp_owner_safe_error_param",
                 "error" => %{
                   "code" => "upstream_terminal_failure",
                   "param" => "reasoning.effort",
                   "message" => message_sentinel,
                   "value" => value_sentinel,
                   "token" => token_sentinel
                 },
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
               }
             }}
          ],
          done: false,
          headers: [{"x-owner-raw-header", header_sentinel}]
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-safe-error-param", "owner-safe-error-param")

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, "owner forwarded terminal failure")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, terminal_frame}, state} = receive_owner_socket_push(state)
          assert %{"type" => "response.failed"} = Jason.decode!(terminal_frame)
          assert {:ok, completed_state} = receive_socket_done(state)
          assert :ok = CodexResponsesSocket.terminate(:closed, completed_state)
          assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.response_status_code == 200
    assert request.last_error_code == "upstream_terminal_failure"
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.response_metadata["upstream_error_param"] == "reasoning.effort"

    assert [turn] =
             Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id))

    assert turn.status == "failed"
    assert turn.error_code == "upstream_terminal_failure"
    assert Repo.get!(CodexSession, state.codex_session.id).status == "active"

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.websocket_owner_lease_token

    assert {:ok, _owner} = WebsocketOwnerSession.lookup(state.codex_session.id)

    assert Repo.aggregate(
             from(e in LedgerEntry,
               where: e.request_id == ^request.id and e.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert [demotion] = Repo.all(from(d in BridgeDemotion))
    assert demotion.reason_code == "upstream_terminal_failure"

    assert [circuit] =
             Repo.all(from(c in RoutingCircuitState, where: c.route_class == "proxy_websocket"))

    assert circuit.reason_code == "upstream_terminal_failure"

    persisted = inspect({request.request_metadata, attempt.response_metadata})

    for raw_sentinel <- [
          message_sentinel,
          value_sentinel,
          frame_sentinel,
          header_sentinel,
          token_sentinel,
          setup.authorization,
          setup.raw_key,
          "upstream-token"
        ] do
      refute persisted =~ raw_sentinel
      refute logs =~ raw_sentinel
    end
  end

  @tag :f2_owner_terminal_error_param
  test "owner-forwarded invalid first error param does not fall back or persist raw diagnostics" do
    message_sentinel = "owner-invalid-message-sentinel"
    value_sentinel = "owner-invalid-value-sentinel"
    frame_sentinel = "owner-invalid-frame-sentinel"
    header_sentinel = "owner-invalid-header-sentinel"
    token_sentinel = "owner-invalid-token-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "raw_frame" => frame_sentinel,
               "response" => %{
                 "id" => "resp_owner_invalid_error_param",
                 "error" => %{
                   "code" => "unsupported_value",
                   "param" => "invalid param #{value_sentinel}",
                   "message" => message_sentinel,
                   "value" => value_sentinel,
                   "token" => token_sentinel
                 }
               },
               "error" => %{"param" => "reasoning.effort"}
             }}
          ],
          done: false,
          headers: [{"x-owner-raw-header", header_sentinel}]
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-invalid-error-param", "owner-invalid-error-param")

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, "owner forwarded invalid terminal parameter")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, terminal_frame}, state} = receive_owner_socket_push(state)
          assert %{"type" => "response.failed"} = Jason.decode!(terminal_frame)
          assert {:ok, completed_state} = receive_socket_done(state)
          assert :ok = CodexResponsesSocket.terminate(:closed, completed_state)
          assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.response_status_code == 200
    assert request.last_error_code == "unsupported_value"
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    refute Map.has_key?(attempt.response_metadata, "upstream_error_param")

    assert [turn] =
             Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id))

    assert turn.status == "failed"
    assert turn.error_code == "unsupported_value"
    assert Repo.get!(CodexSession, state.codex_session.id).status == "active"

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.websocket_owner_lease_token

    assert {:ok, _owner} = WebsocketOwnerSession.lookup(state.codex_session.id)

    assert Repo.aggregate(
             from(e in LedgerEntry,
               where: e.request_id == ^request.id and e.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    persisted = inspect({request.request_metadata, attempt.response_metadata})

    for raw_sentinel <- [
          message_sentinel,
          value_sentinel,
          frame_sentinel,
          header_sentinel,
          token_sentinel,
          setup.authorization,
          setup.raw_key,
          "upstream-token"
        ] do
      refute persisted =~ raw_sentinel
      refute logs =~ raw_sentinel
    end
  end

  test "owner-forwarded upstream close before terminal persists safe transport metadata" do
    raw_event_type = "response.private_event_sentinel_deadbeef"

    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close(
          [
            {raw_event_type,
             %{
               "type" => raw_event_type,
               "response_id" => "resp_owner_transport_failure",
               "output_index" => 0,
               "content_index" => 0,
               "delta" => @sentinel
             }}
          ],
          reason: "owner upstream close reason sentinel"
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-transport-failure", "owner-transport-failure")

    payload =
      websocket_payload(setup, "owner forwarded transport failure", %{
        "request_id" => "ws-owner-transport-failure"
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert {:push, {:text, partial_frame}, state} = receive_owner_socket_push(state)

    assert %{"type" => ^raw_event_type, "delta" => @sentinel} =
             Jason.decode!(partial_frame)

    assert {:push, {:text, owner_error_frame}, state} = receive_owner_socket_push(state)

    assert %{"type" => "error", "error" => %{"code" => "server_error"}} =
             Jason.decode!(owner_error_frame)

    assert {:push, {:text, error_frame}, failed_state} = receive_socket_done(state)

    assert_receive {:websocket_owner_frame, _, _, _, :complete} = owner_complete
    assert {:ok, failed_state} = CodexResponsesSocket.handle_info(owner_complete, failed_state)

    assert %{"type" => "error", "error" => %{"code" => "upstream_request_failed"}} =
             Jason.decode!(error_frame)

    assert failed_state.websocket_owner_active_turn_reconnect? == false
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0

    assert [request_log] = request_logs(setup.pool.id)
    assert request_log.status == "failed"
    assert request_log.transport == "websocket"
    assert request_log.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_log.id))
    assert attempt.status == "failed"
    assert_forwarding_cardinality!(request_log, state.codex_session.id, "failed")

    connection = attempt.response_metadata["upstream_websocket_connection"]

    assert %{"lifecycle_id" => lifecycle_id} = connection
    assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

    assert connection == %{
             "lifecycle_id" => lifecycle_id,
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           }

    assert attempt.response_metadata["transport_failure"] == %{
             "connection_age_bucket" => "under_1m",
             "connection_idle_bucket" => "first_request",
             "connection_request_bucket" => "first",
             "connection_use" => "fresh",
             "last_upstream_event_class" => "response_unknown_event",
             "last_upstream_event_type" => "response.unknown",
             "peer_close_code" => 1001,
             "peer_close_reason_bytes" => 36,
             "peer_close_reason_present" => true,
             "phase" => "upstream_close",
             "pre_visible_output" => false,
             "reason" => "upstream_websocket_closed_before_terminal",
             "reason_class" => "upstream_websocket_closed_before_terminal",
             "terminal_candidate_seen" => false,
             "terminal_seen" => false,
             "termination_source" => "peer_close_frame",
             "text_frame_count" => 1,
             "transport_signal" => "tcp_data",
             "upstream_committed" => true,
             "websocket_buffer_bucket" => "empty",
             "websocket_fragment_open" => false
           }

    metadata_text = inspect(attempt.response_metadata)
    refute metadata_text =~ raw_event_type
    refute metadata_text =~ @sentinel
    refute metadata_text =~ "owner upstream close reason sentinel"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
    await_owner_cleanup!(failed_state.codex_session.id)
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "owner-forwarded websocket terminal auth refresh retries through the same owner session" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream(
             [
               {"response.failed",
                %{
                  "type" => "response.failed",
                  "response" => %{
                    "id" => "resp_owner_auth_terminal",
                    "error" => %{"code" => "invalid_api_key"},
                    "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
                  }
                }}
             ],
             done: true
           ),
           FakeUpstream.json_response(%{"access_token" => "owner-upstream-token-refreshed"}, 200),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_auth_retry_success",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-owner-ws-terminal-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-auth-refresh", "owner-auth-refresh")

    try do
      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {websocket_payload(setup, "owner auth refresh"), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_auth_retry_success"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert [first_request, refresh_request, retried_request] =
               await_upstream_requests(upstream, 3)

      assert first_request.method == "WEBSOCKET"
      assert refresh_request.path == "/oauth/token"
      assert retried_request.method == "WEBSOCKET"

      assert Map.new(retried_request.headers)["authorization"] ==
               "Bearer owner-upstream-token-refreshed"

      assert first_request.websocket_connection_id != retried_request.websocket_connection_id
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [first_opaque_connection_id, second_opaque_connection_id] =
               FakeUpstream.websocket_connection_ids(upstream)

      assert is_reference(first_opaque_connection_id)
      assert is_reference(second_opaque_connection_id)
      assert first_opaque_connection_id != second_opaque_connection_id

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 1
      assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

      owner_metadata = request.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

      assert [first_attempt, second_attempt] =
               Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_unauthorized"
      assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert second_attempt.status == "succeeded"

      first_connection = first_attempt.response_metadata["upstream_websocket_connection"]
      second_connection = second_attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id} = first_connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

      assert first_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 1,
               "reused" => false,
               "reconnected" => false
             }

      assert second_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 2,
               "reused" => false,
               "reconnected" => false
             }

      metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "refresh-token-owner-ws-terminal-do-not-leak"
      refute metadata_text =~ "owner-upstream-token-refreshed"
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded pre-visible assignment model miss retries a later assignment" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.sse_stream(
             [
               {"response.failed",
                %{
                  "type" => "response.failed",
                  "response" => %{
                    "id" => "resp_owner_assignment_model_miss",
                    "error" => %{
                      "code" => "model_not_found",
                      "message" => "raw owner model miss sentinel"
                    }
                  }
                }}
             ],
             done: true
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_assignment_model_fallback_success",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    setup = gateway_setup(upstream, exposed_model_id: "gpt-example-luna")

    second =
      gateway_upstream(setup.pool, upstream, "upstream-token-owner-model-fallback",
        compact?: false
      )

    prime_routing_quota!(second.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
      )

    request_id = Ecto.UUID.generate()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, request_id, request_id)

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {websocket_payload(setup, "owner assignment model failover", %{
                    "request_id" => request_id
                  }), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_assignment_model_fallback_success"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.count(upstream) == 2

      assert [first_opaque_connection_id, second_opaque_connection_id] =
               FakeUpstream.websocket_connection_ids(upstream)

      assert is_reference(first_opaque_connection_id)
      assert is_reference(second_opaque_connection_id)
      assert first_opaque_connection_id != second_opaque_connection_id

      assert [first_attempt, second_attempt] =
               Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      refute first_attempt.pool_upstream_assignment_id ==
               second_attempt.pool_upstream_assignment_id

      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_model_unavailable"
      assert first_attempt.usage_status == "usage_unknown"
      assert second_attempt.status == "succeeded"
      assert second_attempt.usage_status == "usage_known"

      first_connection = first_attempt.response_metadata["upstream_websocket_connection"]
      second_connection = second_attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id} = first_connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

      assert first_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 1,
               "reused" => false,
               "reconnected" => false
             }

      assert second_connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 2,
               "reused" => false,
               "reconnected" => false
             }

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 1

      assert [settlement] =
               Repo.all(
                 from(entry in LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 )
               )

      assert settlement.attempt_id == second_attempt.id
      assert settlement.pool_upstream_assignment_id == second_attempt.pool_upstream_assignment_id
      assert settlement.usage_status == "usage_known"
      assert settlement.total_tokens == 7

      assert %RoutingCircuitState{
               pool_upstream_assignment_id: first_assignment_id,
               route_class: "proxy_websocket",
               reason_code: "upstream_model_unavailable"
             } = Repo.one!(from(c in RoutingCircuitState))

      assert first_assignment_id == first_attempt.pool_upstream_assignment_id

      assert %BridgeDemotion{
               pool_upstream_assignment_id: demoted_assignment_id,
               reason_code: "upstream_model_unavailable"
             } = Repo.one!(from(d in BridgeDemotion))

      assert demoted_assignment_id == first_attempt.pool_upstream_assignment_id

      persisted = inspect({request, first_attempt, second_attempt})
      refute persisted =~ "raw owner model miss sentinel"
      refute persisted =~ "owner assignment model failover"
      refute persisted =~ setup.authorization
      refute persisted =~ "upstream-token-owner-model-fallback"
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "successful remote owner detach preserves the active session lease and accounting" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_remote_node_success",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-remote-success", "owner-remote-success")
    owner_lease = active_owner_lease(state.codex_session.id)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-owner-success.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :success},
              capture_request_to: self()
            )
          )
    }

    try do
      opts =
        Gateway.websocket_owner_response_options(
          remote_state.opts,
          remote_state.codex_session,
          remote_state.websocket_owner_lease_token,
          remote_state.websocket_owner_downstream
        )

      handoff = AgentV2ContractFixture.handoff!(:send_message)

      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_input_payload(setup, [handoff]),
                 opts,
                 fn _data -> :ok end
               )

      assert {:push, {:text, frame}, remote_state} = receive_owner_socket_push(remote_state)
      assert %{"id" => "resp_owner_remote_node_success"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_owner_socket_complete(remote_state)

      assert_remote_submit_request_v1!(remote_state, remote_node, :success)

      assert FakeUpstream.count(upstream) == 1
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == [handoff]
      assert [opaque_connection_id] = FakeUpstream.websocket_connection_ids(upstream)
      assert is_reference(opaque_connection_id)
      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.transport == "websocket"

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"
      assert attempt.transport == "websocket"

      connection = attempt.response_metadata["upstream_websocket_connection"]

      assert %{"lifecycle_id" => lifecycle_id} = connection
      assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)

      assert connection == %{
               "lifecycle_id" => lifecycle_id,
               "generation" => 1,
               "reused" => false,
               "reconnected" => false
             }

      assert [settlement] =
               Repo.all(
                 from(entry in LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 )
               )

      assert settlement.attempt_id == attempt.id
      assert settlement.transport == "websocket"
      assert_forwarding_cardinality!(request, state.codex_session.id, "succeeded")
      refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
      assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
      assert Repo.get!(CodexSession, state.codex_session.id).status == "active"
      assert Repo.get!(BridgeOwnerLease, owner_lease.id).status == "active"
      assert active_owner_lease(state.codex_session.id).lease_token == owner_lease.lease_token
      assert Repo.get!(Request, request.id).status == "succeeded"
      assert Repo.get!(Attempt, attempt.id).status == "succeeded"

      assert Repo.get_by!(CodexTurn, request_id: request.id).status == "succeeded"
      assert Process.alive?(owner_pid)
      assert WebsocketOwnerSession.lookup(state.codex_session.id) == {:ok, owner_pid}

      assert {:ok, reuse_state} =
               owner_socket(
                 auth,
                 "ws-owner-remote-success-reuse",
                 "owner-remote-success"
               )

      assert reuse_state.codex_session.id == state.codex_session.id
      assert reuse_state.websocket_owner_lease_token == owner_lease.lease_token
      assert :ok = CodexResponsesSocket.terminate(:closed, reuse_state)
      assert Repo.get!(CodexSession, state.codex_session.id).status == "active"
      assert Repo.get!(BridgeOwnerLease, owner_lease.id).status == "active"
    after
      CodexResponsesSocket.terminate(
        :closed,
        Map.delete(remote_state, :websocket_owner_downstream)
      )
    end
  end

  @tag :replay_matrix
  @tag :replay_topology
  test "remote owner forwarding replays one pre-visible disconnect into one completed lifecycle" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_close_without_terminal_barrier(
             notify: self(),
             release_ref: release_ref,
             code: 1001,
             reason: "synthetic remote replay disconnect"
           ),
           FakeUpstream.websocket_text_frames([
             Jason.encode!(%{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_remote_replay_complete",
                 "status" => "completed",
                 "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
               }
             })
           ])
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = Ecto.UUID.generate()
    {:ok, state} = owner_socket(auth, "ws-remote-replay", turn_state)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-replay.example"
    ReplayRemoteNodeClient.configure(remote_node, self())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      state.codex_session
      |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
      |> Repo.update!()

    active_owner_lease(session.id)
    |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
    |> Repo.update!()

    :sys.replace_state(owner_pid, fn owner_state ->
      %{owner_state | owner_instance_id: Atom.to_string(remote_node)}
    end)

    node_client_options = [node_client: ReplayRemoteNodeClient]

    remote_state =
      state
      |> remote_owner_state(remote_node, node_client_options)
      |> Map.put(:codex_session, session)

    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [
          %{
            "type" => "function_call_output",
            "call_id" => "call_remote_replay",
            "output" => "synthetic remote replay output"
          }
        ],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              Jason.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "remote-replay-turn",
                "request_kind" => "turn"
              })
          }
        }
      )

    assert {:ok, remote_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, remote_state)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   @handoff_detection_timeout_ms

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}

    assert_receive {:replay_remote_owner_call, ^remote_node,
                    :remote_prepare_next_replay_descriptor}

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v1}
    assert %{active_turn: %{descriptor: %{replay_generation: 0}}} = :sys.get_state(owner_pid)

    assert Gateway.detach_websocket_owner_downstream(
             session,
             remote_state.websocket_owner_lease_token,
             remote_state.websocket_owner_downstream,
             remote_state.opts
           ) in [:suspended, :ok]

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_cancel_downstream}

    assert %{active_turn: nil, suspended_replay: %{provisional_status: :armed}} =
             :sys.get_state(owner_pid)

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:ok, remote_state} = receive_socket_done(remote_state)
    assert MapSet.size(remote_state.tasks) == 0

    assert [request] = request_logs(setup.pool.id)
    assert [initial_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert initial_attempt.replay_generation == 0
    assert initial_attempt.status == "retryable_failed"

    assert %RequestReplayEntitlement{status: "armed", closed_at: nil} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    {:ok, replay_state} =
      owner_socket(auth, "ws-remote-replay-retry", turn_state,
        websocket_owner_forwarder_opts: node_client_options
      )

    assert {:ok, replay_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, replay_state)

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_consume_replay_reserve}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_validate_replay_reserve}
    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_reconnect_control_v2}

    assert_receive {:replay_remote_owner_call, ^remote_node,
                    :remote_prepare_next_replay_descriptor}

    assert_receive {:replay_remote_owner_call, ^remote_node, :remote_submit_request_v4}

    assert {:push, {:text, replay_frame}, replay_state} = receive_owner_socket_push(replay_state)
    assert %{"type" => "response.completed"} = Jason.decode!(replay_frame)
    assert {:ok, replay_state} = receive_owner_socket_complete(replay_state)
    assert {:ok, replay_state} = receive_socket_done(replay_state)

    assert [%Request{id: request_id}] = request_logs(setup.pool.id)
    assert request_id == request.id

    assert [attempt_n, attempt_n_plus_one] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert {attempt_n.replay_generation, attempt_n_plus_one.replay_generation} == {0, 1}
    assert attempt_n_plus_one.status == "succeeded"
    assert FakeUpstream.count(upstream) == 2

    assert %RequestReplayEntitlement{status: "consumed", closed_at: %DateTime{}} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "reservation"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "release"
             ),
             :count
           ) == 1

    assert [%CodexTurn{status: "succeeded", final_attempt_id: final_attempt_id}] =
             Repo.all(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    assert final_attempt_id == attempt_n_plus_one.id
    assert :ok = CodexResponsesSocket.terminate(:closed, replay_state)
    assert Process.alive?(owner_pid)
  end

  @tag :replay_matrix
  @tag :replay_race
  @tag :replay_topology
  @tag :replay_cleanup
  test "real peer owner replays one pre-visible disconnect through the non-owner proxy" do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)

    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_close_without_terminal_barrier(
             notify: self(),
             release_ref: release_ref,
             code: 1001,
             reason: "synthetic real peer replay disconnect"
           ),
           FakeUpstream.websocket_text_frames([
             Jason.encode!(%{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_real_peer_replay_complete",
                 "status" => "completed",
                 "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
               }
             })
           ])
         ]}
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    turn_state = Ecto.UUID.generate()
    session_header = "real-peer-replay-#{System.unique_integer([:positive])}"
    {session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)
    assert node(owner_pid) == remote_node
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(session.id)

    assert {:ok, ^owner_pid} =
             :erpc.call(remote_node, WebsocketOwnerSession, :lookup, [session.id])

    assert node(
             :erpc.call(remote_node, :erlang, :map_get, [:upstream_pid, :sys.get_state(owner_pid)])
           ) ==
             remote_node

    forwarder_opts = [
      node_client: WebsocketOwnerForwarder.ERPCNodeClient,
      app_node_names: [Atom.to_string(remote_node)]
    ]

    {:ok, state} =
      owner_socket(auth, "ws-real-peer-replay", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [
          %{
            "type" => "function_call_output",
            "call_id" => "call_real_peer_replay",
            "output" => "synthetic real peer replay output"
          }
        ],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              Jason.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "real-peer-replay-turn",
                "request_kind" => "turn"
              })
          }
        }
      )

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   @handoff_detection_timeout_ms

    remote_owner_state = :erpc.call(remote_node, :sys, :get_state, [owner_pid])
    assert remote_owner_state.codex_session_id == session.id
    assert remote_owner_state.owner_instance_id == Atom.to_string(remote_node)
    assert remote_owner_state.active_turn.descriptor.replay_generation == 0

    assert Gateway.detach_websocket_owner_downstream(
             session,
             state.websocket_owner_lease_token,
             state.websocket_owner_downstream,
             state.opts
           ) in [:suspended, :ok]

    assert %{active_turn: nil, suspended_replay: %{provisional_status: :armed}} =
             :erpc.call(remote_node, :sys, :get_state, [owner_pid])

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:ok, state} = receive_socket_done(state)
    assert MapSet.size(state.tasks) == 0

    assert [request] = request_logs(setup.pool.id)
    assert [initial_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert initial_attempt.replay_generation == 0
    assert initial_attempt.status == "retryable_failed"

    {:ok, replay_state} =
      owner_socket(auth, "ws-real-peer-replay-retry", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    assert {:ok, replay_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, replay_state)

    assert {:push, {:text, replay_frame}, replay_state} =
             receive_owner_socket_push(replay_state)

    assert %{"type" => "response.completed"} = Jason.decode!(replay_frame)
    assert {:ok, replay_state} = receive_owner_socket_complete(replay_state)
    assert {:ok, replay_state} = receive_socket_done(replay_state)

    assert [attempt_n, attempt_n_plus_one] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert {attempt_n.replay_generation, attempt_n_plus_one.replay_generation} == {0, 1}
    assert attempt_n_plus_one.status == "succeeded"
    assert FakeUpstream.count(upstream) == 2

    assert Repo.aggregate(from(r in Request, where: r.id == ^request.id), :count) == 1
    assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^request.id), :count) == 1

    for kind <- ["reservation", "settlement", "release"] do
      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == ^kind
               ),
               :count
             ) == 1
    end

    assert [%CodexTurn{status: "succeeded", final_attempt_id: final_attempt_id}] =
             Repo.all(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    assert final_attempt_id == attempt_n_plus_one.id

    assert %RequestReplayEntitlement{status: "consumed", closed_at: %DateTime{}} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    {:ok, duplicate_state} =
      owner_socket(auth, "ws-real-peer-replay-duplicate", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    assert {:ok, duplicate_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, duplicate_state)

    assert {:push, {:text, duplicate_frame}, duplicate_state} =
             receive_socket_done(duplicate_state)

    assert Jason.decode!(duplicate_frame)["error"]["code"] == "duplicate_turn"
    assert FakeUpstream.count(upstream) == 2
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 2

    assert :ok = CodexResponsesSocket.terminate(:closed, duplicate_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, replay_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    stop_remote_owner!(remote_node, session.id, owner_pid)
  end

  @tag :client_retry_owner_race
  test "two proxy downstreams race one client retry through the real peer owner" do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)

    release_ref = make_ref()

    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_client_retry_owner_race",
          "status" => "completed",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        }
      })

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(
          terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    session_header = "client-retry-owner-race-#{System.unique_integer([:positive])}"
    {session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)

    forwarder_opts = [
      node_client: WebsocketOwnerForwarder.ERPCNodeClient,
      app_node_names: [Atom.to_string(remote_node)]
    ]

    turn_state = Ecto.UUID.generate()

    {:ok, first_state} =
      owner_socket(auth, "client-retry-owner-a", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    {:ok, second_state} =
      owner_socket(auth, "client-retry-owner-b", turn_state,
        session_header: session_header,
        session_header_source: "x-session-id",
        websocket_owner_forwarder_opts: forwarder_opts
      )

    thread_id = Ecto.UUID.generate()

    payload =
      websocket_input_payload(
        setup,
        [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic retry input"}]
          }
        ],
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              Jason.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "client-retry-owner-race",
                "request_kind" => "turn"
              })
          }
        }
      )

    options =
      Gateway.websocket_owner_response_options(
        first_state.opts,
        first_state.codex_session,
        first_state.websocket_owner_lease_token,
        first_state.websocket_owner_downstream
      )
      |> RequestOptions.capture_api_key_runtime_epoch(auth)

    {:ok, prepared} = Service.prepare_websocket_response(payload, options, fn _frame -> :ok end)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, %{request: predecessor}} =
      Accounting.claim_websocket_turn(auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: Ecto.UUID.generate(),
        native_client_retry_witness: prepared.native_client_retry_witness
      })

    assert predecessor.native_client_retry_version == 1
    assert predecessor.native_client_retry_digest == prepared.replay_claim_digest

    predecessor_turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: predecessor.id,
        turn_sequence: 1,
        transport_kind: "websocket",
        semantic_turn_digest: prepared.semantic_turn_key,
        status: "failed",
        error_code: "upstream_stream_error",
        first_visible_output_at: now,
        completed_at: now,
        started_at: now,
        created_at: now,
        updated_at: now
      })

    predecessor_attempt =
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

    Repo.update!(
      Ecto.Changeset.change(predecessor,
        status: "failed",
        usage_status: "usage_unknown",
        completed_at: now,
        last_error_code: "upstream_stream_error"
      )
    )

    Repo.update!(
      Ecto.Changeset.change(predecessor_turn, final_attempt_id: predecessor_attempt.id)
    )

    assert {:ok, current_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, upstream_pid,
                    ^release_ref},
                   @handoff_detection_timeout_ms

    loser_result = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, first_state)

    assert {:push, {:text, loser_error}, _loser_state} = loser_result
    assert Jason.decode!(loser_error)["error"]["code"] in ["duplicate_turn", "owner_busy"]

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    assert {:push, {:text, _frame}, current_state} = receive_owner_socket_push(current_state)
    assert {:ok, current_state} = receive_owner_socket_complete(current_state)
    assert {:ok, _current_state} = receive_socket_done(current_state)

    assert Repo.aggregate(RequestClientRetryLink, :count) == 1

    successor_id = Repo.one!(from l in RequestClientRetryLink, select: l.successor_request_id)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^successor_id), :count) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert node(owner_pid) == remote_node

    {successor, _attempt, _turn, _settlement, _fact} =
      await_forwarding_persistence!(successor_id, session.id, "succeeded")

    assert successor.id == successor_id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where:
                 entry.request_id == ^successor_id and entry.entry_kind == "settlement" and
                   entry.amount_status == "recorded"
             ),
             :count
           ) == 1
  end

  test "a paused key stops a remote-owner-shaped turn at reservation without dispatch or recovery" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-api-key-fence", "owner-api-key-fence")
    remote_node = :"codex_pooler@remote-owner-api-key-fence.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(state, remote_node, node_opts)
    opts = owner_response_options(remote_state, node_opts)
    barrier_ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        Process.put(
          {Reservation, :runtime_authorization_barrier},
          {parent, barrier_ref, {:reserve, :before}}
        )

        Process.put(
          {Service, :runtime_authorization_barrier},
          {parent, barrier_ref, {:reserve, :before}}
        )

        Gateway.run_websocket_response_for_socket(
          auth,
          websocket_payload(setup, "remote owner durable fence"),
          opts,
          fn _frame -> :ok end
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)

    try do
      assert remote_state.codex_session.owner_instance_id == Atom.to_string(remote_node)

      assert_receive {:runtime_authorization_barrier, ^barrier_ref, :reserve, :before, task_pid},
                     1_000

      assert task_pid == task.pid
      assert request_logs(setup.pool.id) == []

      assert {:ok, paused_key} = Access.pause_api_key(model_serving_scope(), setup.api_key)
      assert paused_key.status == "paused"
      send(task.pid, {:runtime_authorization_release, barrier_ref})

      assert {:socket_response_result, :local_complete,
              {:error, %{code: :api_key_paused, disabling_epoch: disabling_epoch}}} =
               Task.await(task, 15_000)

      assert disabling_epoch == paused_key.runtime_revocation_epoch

      assert [%Request{status: "rejected", last_error_code: "api_key_paused"}] =
               request_logs(setup.pool.id)

      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
      assert Repo.aggregate(CodexTurn, :count) == 0
      assert FakeUpstream.count(upstream) == 0
      refute_received {:websocket_owner_harness_node_call, _call}
      refute_received {:websocket_owner_frame, _, _, _}
      refute_received {:websocket_owner_frame, _, _, _, _}
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :native_observer_failure
  test "owner-forwarded frame observer failure still delivers one terminal" do
    marker = "synthetic-owner-observer-marker-#{System.unique_integer([:positive])}"
    input_marker = "synthetic-owner-observer-input-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_observer_failure",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    upstream_boundary = frame_observer_failure_upstream_boundary(self(), marker)

    {:ok, state} =
      owner_socket(auth, "ws-owner-observer-failure", "owner-observer-failure",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, input_marker)

          assert {:ok, state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

          assert {:push, {:text, terminal}, state} = receive_owner_socket_push(state)

          assert %{"id" => "resp_owner_observer_failure"} = Jason.decode!(terminal)
          assert {:ok, state} = receive_owner_socket_complete(state)
          flush_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_receive {:owner_frame_observer_failed, observer_pid}
    assert is_pid(observer_pid)
    refute_received {:owner_frame_observer_failed, _duplicate}
    refute_received {:websocket_owner_frame, _, _, _duplicate_terminal}
    assert logs =~ "upstream websocket frame observer failed operation=observe_frame"
    refute logs =~ marker
    refute logs =~ setup.authorization
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0

    assert [request] = request_logs(setup.pool.id)
    assert request.transport == "websocket"
    rows = assert_forwarding_cardinality!(request, state.codex_session.id, "succeeded")
    assert_no_markers_persisted!(rows, setup.pool.id, [marker, input_marker])
    refute logs =~ input_marker
    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
  end

  @tag :public_remote_success
  test "public responses bridge remote v1 success settles and delivers one terminal", %{
    conn: conn
  } do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
    response_id = "resp_owner_public_remote_#{System.unique_integer([:positive])}"
    marker = "synthetic-public-remote-marker-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => response_id,
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    session_header = "public-owner-success-#{System.unique_integer([:positive])}"
    {_session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)

    {response, logs} =
      with_log(fn ->
        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_header)
        |> post("/v1/responses", public_stream_payload(setup, marker))
      end)

    assert response.status == 200

    assert [
             %{
               "event" => "response.created",
               "data" => %{
                 "type" => "response.created",
                 "response" => %{"id" => ^response_id, "status" => "in_progress"}
               }
             },
             %{"event" => "response.completed", "data" => terminal}
           ] = public_stream_events(response.resp_body)

    assert terminal["type"] == "response.completed"
    assert get_in(terminal, ["response", "id"]) == response_id
    refute response.resp_body =~ marker
    refute logs =~ marker
    refute logs =~ setup.authorization
    assert_bridge_v1_submission!(remote_node)
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert inspect(%{body: upstream_request.body, json: upstream_request.json}) =~ marker

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    rows = assert_forwarding_cardinality!(request, nil, "succeeded")
    assert_no_markers_persisted!(rows, setup.pool.id, [marker])

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["upstream_websocket_bridge"] == true
    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
    assert node(owner_pid) == remote_node
    assert :erpc.call(remote_node, Process, :alive?, [owner_pid])
  end

  test "admitted native proxy starts a real peer upstream before terminal delivery acknowledgement" do
    ensure_test_distribution_started!()
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
    use_fresh_rollout_drain!()
    release_ref = make_ref()
    response_id = "resp_native_proxy_predispatch_#{System.unique_integer([:positive])}"

    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed"}
      })

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(
          terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    register_unboxed_pool_cleanup!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:current, setup.identity, repo: :real)
    refute OperationalStatus.draining?()
    refute :erpc.call(remote_node, OperationalStatus, :draining?, [])
    session_header = "native-proxy-predispatch-#{System.unique_integer([:positive])}"
    {_session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node, :real)

    {:ok, state} =
      owner_socket(auth, "ws-native-proxy-predispatch", "native-proxy-predispatch",
        session_header: session_header,
        session_header_source: "x-session-id"
      )

    try do
      payload = websocket_payload(setup, "native proxy predispatch")
      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid,
                      ^release_ref},
                     5_000

      assert MapSet.size(state.tasks) == 1
      [task_pid] = MapSet.to_list(state.tasks)
      refute_received {:websocket_response_activity, _task_pid, _activity_token}
      send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

      assert_receive {:websocket_owner_frame, correlation_id, epoch, _owner_turn_id,
                      {:data, ^terminal}} =
                       terminal_message,
                     5_000

      assert {:push, {:text, ^terminal}, state} =
               CodexResponsesSocket.handle_info(terminal_message, state)

      assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, _owner_turn_id, :complete} =
                       complete_message,
                     5_000

      assert {:ok, state} = CodexResponsesSocket.handle_info(complete_message, state)
      assert_receive {:websocket_response_activity, ^task_pid, activity_token} = activity_message
      assert {:ok, state} = CodexResponsesSocket.handle_info(activity_message, state)
      assert_receive {:codex_response_done, ^task_pid, _result} = done_message
      assert {:ok, state} = CodexResponsesSocket.handle_info(done_message, state)

      assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token} =
                       delivery_message

      assert {:ok, _state} = CodexResponsesSocket.handle_info(delivery_message, state)
      assert FakeUpstream.count(upstream) == 1
      assert :erpc.call(remote_node, Process, :alive?, [owner_pid])

      assert_receive {:fake_upstream_websocket_barrier, :before_close, close_pid, ^release_ref}
      send(close_pid, {:fake_upstream_release_websocket, release_ref})
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "native proxy turn replaces the attach timeout with the full request budget" do
    terminal =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_owner_turn_budget", "status" => "completed"}
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([terminal]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-turn-budget", "owner-turn-budget")
    remote_node = :"codex_pooler@turn-budget-owner.example"
    TurnBudgetNodeClient.configure(remote_node, self(), 15_000)

    node_opts = [
      node_client: TurnBudgetNodeClient,
      timeout: WebsocketOwnerContract.default_forward_timeout_ms()
    ]

    remote_state = remote_owner_state(state, remote_node, node_opts)

    try do
      payload = websocket_payload(setup, "owner turn budget")

      assert {:ok, remote_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, remote_state)

      [task_pid] = MapSet.to_list(remote_state.tasks)

      assert_receive {:turn_budget_remote_call, :remote_submit_request_v1, 1_801_000}

      assert_receive {:websocket_owner_frame, correlation_id, epoch, _owner_turn_id,
                      {:data, ^terminal}} =
                       terminal_message

      assert {:push, {:text, ^terminal}, remote_state} =
               CodexResponsesSocket.handle_info(terminal_message, remote_state)

      assert_receive {:websocket_owner_frame, ^correlation_id, ^epoch, _owner_turn_id, :complete} =
                       complete_message

      assert {:ok, remote_state} =
               CodexResponsesSocket.handle_info(complete_message, remote_state)

      assert_receive {:websocket_response_activity, ^task_pid, activity_token} = activity_message

      assert {:ok, remote_state} =
               CodexResponsesSocket.handle_info(activity_message, remote_state)

      assert_receive {:codex_response_done, ^task_pid, _result} = done_message
      assert {:ok, remote_state} = CodexResponsesSocket.handle_info(done_message, remote_state)

      assert_receive {:websocket_response_delivery_complete, ^task_pid, ^activity_token} =
                       delivery_message

      assert {:ok, _state} = CodexResponsesSocket.handle_info(delivery_message, remote_state)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :public_protocol_fallback
  test "public responses bridge protocol incompatibility falls back before commit once", %{
    conn: conn
  } do
    ensure_test_distribution_started!()
    response_id = "resp_owner_public_fallback_#{System.unique_integer([:positive])}"
    marker = "synthetic-public-protocol-marker-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => response_id,
               "status" => "completed",
               "output" => [],
               "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_node = start_bridge_peer!(:previous, setup.identity)
    session_header = "public-owner-old-release-#{System.unique_integer([:positive])}"
    {_session, owner_pid} = start_remote_bridge_owner!(auth, session_header, remote_node)

    logs =
      capture_log(fn ->
        response =
          conn
          |> auth(setup)
          |> put_req_header("x-session-id", session_header)
          |> post("/v1/responses", public_stream_payload(setup, marker))

        assert response.status == 200

        assert [
                 %{
                   "event" => "response.created",
                   "data" => %{
                     "type" => "response.created",
                     "response" => %{"id" => ^response_id, "status" => "in_progress"}
                   }
                 },
                 %{"event" => "response.completed", "data" => terminal}
               ] = public_stream_events(response.resp_body)

        assert terminal["type"] == "response.completed"
        assert get_in(terminal, ["response", "id"]) == response_id
        refute response.resp_body =~ marker
      end)

    refute :erpc.call(remote_node, :erlang, :function_exported, [
             WebsocketOwnerForwarder,
             :remote_submit_request_v1,
             3
           ])

    assert logs =~ "event=owner_protocol_incompatible"
    refute logs =~ marker
    refute logs =~ setup.authorization

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert FakeUpstream.http_request_count(upstream) == 1
    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert inspect(%{body: upstream_request.body, json: upstream_request.json}) =~ marker
    assert [request] = request_logs(setup.pool.id)
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    rows = assert_forwarding_cardinality!(request, nil, "succeeded")
    assert_no_markers_persisted!(rows, setup.pool.id, [marker])
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.transport == "http_sse"
    refute attempt.response_metadata["upstream_websocket_bridge"]
    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
    assert node(owner_pid) == remote_node
    assert :erpc.call(remote_node, Process, :alive?, [owner_pid])
  end

  test "local and remote owners emit identical native metadata bytes for one turn snapshot" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_local_metadata_parity",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_remote_metadata_parity",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, local_state} = owner_socket(auth, "ws-local-metadata-parity", "local-metadata-parity")

    {:ok, remote_state} =
      owner_socket(auth, "ws-remote-metadata-parity", "remote-metadata-parity")

    remote_node = :"codex_pooler@remote-metadata-parity.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(remote_state, remote_node, node_opts)

    models_conn = build_conn() |> auth(setup) |> get("/backend-api/codex/models")
    assert [models_etag] = get_resp_header(models_conn, "etag")

    try do
      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "local metadata parity"),
                 owner_response_options(local_state, []),
                 fn _data -> :ok end
               )

      assert {:push, {:text, local_metadata}, local_state} =
               receive_owner_socket_raw_push(local_state)

      assert %{
               "type" => "codex.response.metadata",
               "headers" => %{"x-models-etag" => ^models_etag}
             } = Jason.decode!(local_metadata)

      assert {:push, {:text, local_response}, local_state} =
               receive_owner_socket_raw_push(local_state)

      assert owner_response_id(local_response) == "resp_local_metadata_parity"
      assert {:ok, _local_state} = receive_owner_socket_complete(local_state)

      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "remote metadata parity"),
                 owner_response_options(remote_state, node_opts),
                 fn _data -> :ok end
               )

      assert {:push, {:text, remote_metadata}, remote_state} =
               receive_owner_socket_raw_push(remote_state)

      assert remote_metadata == local_metadata

      assert {:push, {:text, remote_response}, remote_state} =
               receive_owner_socket_raw_push(remote_state)

      assert owner_response_id(remote_response) == "resp_remote_metadata_parity"
      assert {:ok, _remote_state} = receive_owner_socket_complete(remote_state)
    after
      CodexResponsesSocket.terminate(:closed, local_state)
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :continuation_generation_boundary
  @tag :replay_topology
  test "direct owner guards a replacement generation and settles once before full retry" do
    assert_owner_continuation_generation_boundary(:direct)
  end

  @tag receiver_delivery_gap: :pin
  test "direct receiver accepts provider frames before response delivery cleanup" do
    assert_receiver_delivery_gap(:frames_first)
  end

  @tag receiver_delivery_gap: :cleanup_first
  test "direct receiver keeps terminal delivery coupled to provider frame acceptance" do
    assert_receiver_delivery_gap(:cleanup_first)
  end

  @tag :continuation_generation_boundary
  @tag :replay_topology
  test "proxy-to-owner guards a replacement generation and settles once before full retry" do
    assert_owner_continuation_generation_boundary(:proxy)
  end

  test "owner-forwarded reset probe success confirms on the owner" do
    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_owner_reset_probe_success"}
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_owner_reset_probe_success",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
             }
           }}
        ])
      )

    usage_upstream = reset_probe_usage_upstream()
    setup = gateway_setup(dispatch_upstream, quota?: false)
    identity = enable_reset_probe!(setup.identity, usage_upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reset-probe-success", "owner-reset-probe-success")
    remote_node = :"codex_pooler@remote-reset-probe-success.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success},
        capture_request_to: self()
      )

    remote_state = unpinned_remote_owner_state(state, remote_node, node_opts)

    try do
      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "owner forwarded reset probe success"),
                 owner_response_options(remote_state, node_opts),
                 fn _data -> :ok end
               )

      assert {:push, {:text, created_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.created"} = Jason.decode!(created_frame)

      assert {:push, {:text, completed_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.completed"} = Jason.decode!(completed_frame)
      assert {:ok, _state} = receive_owner_socket_complete(remote_state)

      assert_remote_submit_request_v1!(remote_state, remote_node, :success)

      refute_received {:websocket_owner_harness_node_call, _duplicate}
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end

    assert_reset_probe_usage_calls!(usage_upstream)
    assert FakeUpstream.count(dispatch_upstream) == 1

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "succeeded"
    assert request.transport == "websocket"
    assert request.retry_count == 0
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
    assert attempt.pool_upstream_assignment_id == setup.assignment.id

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.attempt_id == attempt.id
    assert settlement.transport == "websocket"

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "confirmed_by_upstream"
    assert get_in(redemption, ["result", "code"]) == "reset"

    assert_reset_probe_public_metadata_safe!(request, attempt, redemption, [
      setup.authorization,
      "owner forwarded reset probe success",
      "resp_owner_reset_probe_success"
    ])
  end

  test "owner-forwarded request preserves sibling capacity and does not consume a reset" do
    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_owner_capacity_fence"}
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_owner_capacity_fence",
               "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
             }
           }}
        ])
      )

    usage_upstream = reset_probe_usage_upstream()
    setup = gateway_setup(dispatch_upstream, quota?: false)
    sibling = active_upstream_assignment_fixture(setup.pool, %{})
    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(usage_upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_trigger_mode: "threshold",
        saved_reset_auto_redeem_quota_threshold_percent: 95,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    put_owner_capacity_quota!(identity, "96")
    put_owner_capacity_quota!(sibling.identity, "75")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-capacity-fence", "owner-capacity-fence")
    remote_node = :"codex_pooler@remote-capacity-fence.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success},
        capture_request_to: self()
      )

    remote_state = remote_owner_state(state, remote_node, node_opts)

    session =
      state.codex_session
      |> Ecto.Changeset.change(pool_upstream_assignment_id: setup.assignment.id)
      |> Repo.update!()

    assert Repo.reload!(session).pool_upstream_assignment_id == setup.assignment.id

    remote_state = %{
      remote_state
      | codex_session: %{session | owner_instance_id: Atom.to_string(remote_node)}
    }

    setup = %{setup | model: model}
    request_options = owner_response_options(remote_state, node_opts)

    refute CodexPooler.Gateway.Routing.SessionContinuity.hard_pinned_continuity?(
             request_options,
             model
           )

    assert Enum.sort(model.metadata["source_assignment_ids"]) ==
             Enum.sort([setup.assignment.id, sibling.assignment.id])

    try do
      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 websocket_payload(setup, "owner forwarded capacity fence"),
                 request_options,
                 fn _data -> :ok end
               )

      assert {:push, {:text, created_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.created"} = Jason.decode!(created_frame)

      assert {:push, {:text, completed_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert %{"type" => "response.completed"} = Jason.decode!(completed_frame)
      assert {:ok, _state} = receive_owner_socket_complete(remote_state)
      assert_remote_submit_request_v1!(remote_state, remote_node, :success)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end

    refute Enum.any?(
             FakeUpstream.requests(usage_upstream),
             &(&1.path == "/api/codex/rate-limit-reset-credits/consume")
           )

    refute Map.has_key?(Repo.reload!(identity).metadata, "saved_reset_redemption")
    assert FakeUpstream.count(dispatch_upstream) == 1

    assert [attempt] =
             Repo.all(
               from(a in Attempt,
                 join: r in Request,
                 on: a.request_id == r.id,
                 where: r.pool_id == ^setup.pool.id
               )
             )

    assert attempt.pool_upstream_assignment_id == setup.assignment.id
    assert Repo.reload!(session).pool_upstream_assignment_id == setup.assignment.id
  end

  test "owner-forwarded reset probe terminal failure remains unconfirmed" do
    terminal_message = "owner-reset-terminal-message-sentinel"

    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "response" => %{
               "id" => "resp_owner_reset_probe_failure",
               "error" => %{
                 "code" => "upstream_terminal_failure",
                 "param" => "reasoning.effort",
                 "message" => terminal_message
               }
             }
           }}
        ])
      )

    usage_upstream = reset_probe_usage_upstream()
    setup = gateway_setup(dispatch_upstream, quota?: false)
    identity = enable_reset_probe!(setup.identity, usage_upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reset-probe-failure", "owner-reset-probe-failure")
    remote_node = :"codex_pooler@remote-reset-probe-failure.example"

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success},
        capture_request_to: self()
      )

    remote_state = unpinned_remote_owner_state(state, remote_node, node_opts)

    logs =
      capture_log(fn ->
        try do
          assert :ok =
                   Gateway.run_websocket_response(
                     auth,
                     websocket_payload(setup, "owner forwarded reset probe failure"),
                     owner_response_options(remote_state, node_opts),
                     fn _data -> :ok end
                   )

          assert {:push, {:text, terminal_frame}, remote_state} =
                   receive_owner_socket_push(remote_state)

          assert %{"type" => "response.failed"} = Jason.decode!(terminal_frame)
          assert {:ok, _state} = receive_owner_socket_complete(remote_state)

          assert_remote_submit_request_v1!(remote_state, remote_node, :success)

          refute_received {:websocket_owner_harness_node_call, _duplicate}
        after
          CodexResponsesSocket.terminate(:closed, remote_state)
        end
      end)

    assert_reset_probe_usage_calls!(usage_upstream)
    assert FakeUpstream.count(dispatch_upstream) == 1

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.last_error_code == "upstream_terminal_failure"
    assert request.retry_count == 0

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.pool_upstream_assignment_id == setup.assignment.id

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.attempt_id == attempt.id
    assert settlement.transport == "websocket"

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "consumed_pending_probe"
    assert is_binary(get_in(redemption, ["probe", "token"]))

    assert_reset_probe_public_metadata_safe!(request, attempt, redemption, [
      setup.authorization,
      "owner forwarded reset probe failure",
      "resp_owner_reset_probe_failure",
      terminal_message
    ])

    refute logs =~ get_in(redemption, ["probe", "token"])

    persisted = inspect({request.request_metadata, attempt.response_metadata})
    refute persisted =~ terminal_message
    refute logs =~ terminal_message
  end

  test "remote owner executes the proxy turn snapshot and the next turn observes the Pool edit" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_mode_lite_snapshot",
             "object" => "response",
             "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_mode_full_next_turn",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "lite")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-mode-snapshot", "owner-mode-snapshot")
    remote_node = :"codex_pooler@remote-mode-owner.example"

    base_node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(state, remote_node, base_node_opts)
    release_ref = make_ref()
    parent = self()

    try do
      first_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [
              calls: %{remote_node => {:barrier_success, parent, release_ref}},
              notify: parent,
              capture_request_to: parent
            ],
            fn node_opts ->
              Gateway.run_websocket_response(
                auth,
                model_serving_owner_payload(setup, "remote-lite", "client-false"),
                owner_response_options(remote_state, node_opts),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert_receive {:websocket_owner_harness_call_barrier, rpc_pid, ^release_ref,
                      :remote_submit_request_v1},
                     1_000

      try do
        _revision = set_model_serving_mode!(scope, setup, "full", revision)
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})
        assert :ok = Task.await(first_turn, 3_000)
      after
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})
      end

      assert {:push, {:text, lite_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert owner_response_id(lite_frame) == "resp_owner_mode_lite_snapshot"
      assert {:ok, remote_state} = receive_owner_socket_complete(remote_state)

      assert :ok =
               WebsocketOwnerNodeHarness.with_node_client(
                 [remote_node],
                 [
                   calls: %{remote_node => :success},
                   notify: self(),
                   capture_request_to: self()
                 ],
                 fn node_opts ->
                   Gateway.run_websocket_response(
                     auth,
                     model_serving_owner_payload(setup, "remote-full", "client-true"),
                     owner_response_options(remote_state, node_opts),
                     fn _data -> :ok end
                   )
                 end
               )

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert {:push, {:text, full_frame}, remote_state} =
               receive_owner_socket_push(remote_state)

      assert owner_response_id(full_frame) == "resp_owner_mode_full_next_turn"
      assert {:ok, _remote_state} = receive_owner_socket_complete(remote_state)

      assert [lite_upstream_request, full_upstream_request] = FakeUpstream.requests(upstream)
      assert_canonical_lite_owner_request!(lite_upstream_request)
      assert_canonical_full_owner_request!(full_upstream_request)

      assert [lite_request, full_request] = request_logs(setup.pool.id)
      assert_owner_mode_accounting!(lite_request, "lite", "succeeded", remote_node)
      assert_owner_mode_accounting!(full_request, "full", "succeeded", remote_node)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  test "remote owner loss before visible output recovers without re-resolving the turn mode" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_mode_loss_recovered",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "full")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-mode-loss", "owner-mode-loss")
    remote_node = :"codex_pooler@lost-mode-owner.example"

    base_node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    remote_state = remote_owner_state(state, remote_node, base_node_opts)
    release_ref = make_ref()
    parent = self()

    try do
      lost_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [
              calls: %{
                remote_node =>
                  {:barrier_return, parent, release_ref, {:error, :owner_unavailable}}
              },
              notify: parent,
              capture_request_to: parent
            ],
            fn node_opts ->
              Gateway.run_websocket_response(
                auth,
                model_serving_owner_payload(setup, "remote-owner-loss", "client-true"),
                owner_response_options(remote_state, node_opts),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert_receive {:websocket_owner_harness_call_barrier, rpc_pid, ^release_ref,
                      :remote_submit_request_v1},
                     1_000

      try do
        _revision = set_model_serving_mode!(scope, setup, "lite", revision)
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})

        assert :ok = Task.await(lost_turn, 3_000)
      after
        send(rpc_pid, {:websocket_owner_harness_release_call, release_ref})
      end

      original_downstream = remote_state.websocket_owner_downstream

      assert_receive {:websocket_owner_frame, correlation_id, recovered_epoch,
                      {:data, recovered_metadata_frame}},
                     1_000

      assert correlation_id == original_downstream.correlation_id
      assert recovered_epoch > original_downstream.epoch

      assert %{
               "type" => "codex.response.metadata",
               "headers" => %{"x-models-etag" => _models_etag}
             } = Jason.decode!(recovered_metadata_frame)

      assert_receive {:websocket_owner_frame, ^correlation_id, ^recovered_epoch,
                      {:data, recovered_frame}},
                     1_000

      assert owner_response_id(recovered_frame) == "resp_owner_mode_loss_recovered"

      assert_receive {:websocket_owner_frame, ^correlation_id, ^recovered_epoch, :complete},
                     1_000

      assert [recovered_upstream_request] = FakeUpstream.requests(upstream)
      assert_canonical_full_owner_request!(recovered_upstream_request)

      assert [request] = request_logs(setup.pool.id)
      assert request.retry_count == 0
      assert request.last_error_code == nil
      assert_owner_mode_accounting!(request, "full", "succeeded", remote_node)
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :owner_crash_recovery
  test "replacement owner preserves the active proxy epoch after pre-visible owner death" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream(
             [%{"id" => "resp_owner_mode_killed", "object" => "response"}],
             barrier_after: 0,
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_mode_kill_recovered",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_mode_kill_next_turn",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "lite")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-mode-kill", "owner-mode-kill")
    remote_node = :"codex_pooler@killed-mode-owner.example"

    base_node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )

    stale_downstream = state.websocket_owner_downstream
    {:ok, old_owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

    assert {:ok, active_downstream} =
             WebsocketOwnerSession.attach_downstream(old_owner_pid, %{
               pid: self(),
               correlation_id: stale_downstream.correlation_id
             })

    assert stale_downstream.epoch == 1
    assert active_downstream.epoch == 2

    active_state = %{state | websocket_owner_downstream: active_downstream}
    remote_state = remote_owner_state(active_state, remote_node, base_node_opts)
    old_lease = active_owner_lease(state.codex_session.id)
    old_owner_ref = Process.monitor(old_owner_pid)
    parent = self()

    stale_frame = Jason.encode!(%{"id" => "resp_stale_owner_attachment"})

    assert {:ok, ^remote_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_owner_frame, stale_downstream.correlation_id, stale_downstream.epoch,
                {:data, stale_frame}},
               remote_state
             )

    try do
      interrupted_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [
              calls: %{remote_node => :success},
              notify: parent,
              capture_request_to: parent
            ],
            fn node_opts ->
              Gateway.run_websocket_response(
                auth,
                model_serving_owner_payload(setup, "remote-owner-kill", "client-false"),
                owner_response_options(remote_state, node_opts),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_remote_submit_request_v1!(remote_state, remote_node, nil, 1_000)

      assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref}, 1_000

      try do
        assert [projected_lite_request] = await_upstream_requests(upstream, 1)
        assert_canonical_lite_owner_request!(projected_lite_request)

        assert [in_progress_request] = request_logs(setup.pool.id)
        assert in_progress_request.status == "in_progress"
        assert in_progress_request.retry_count == 0

        assert [in_progress_attempt] =
                 Repo.all(from(a in Attempt, where: a.request_id == ^in_progress_request.id))

        assert in_progress_attempt.status == "in_progress"

        assert in_progress_turn =
                 Repo.one!(from(t in CodexTurn, where: t.request_id == ^in_progress_request.id))

        assert in_progress_turn.status == "in_progress"
        assert is_nil(in_progress_turn.first_visible_output_at)
        assert active_owner_lease(state.codex_session.id).lease_token == old_lease.lease_token

        _revision = set_model_serving_mode!(scope, setup, "full", revision)

        Process.exit(old_owner_pid, :kill)
        assert_receive {:DOWN, ^old_owner_ref, :process, ^old_owner_pid, :killed}, 1_000
        send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

        assert :ok = Task.await(interrupted_turn, 3_000)

        assert_receive {:websocket_owner_runtime_recovered, correlation_id, epoch, runtime},
                       1_000

        assert correlation_id == active_downstream.correlation_id
        assert epoch == active_downstream.epoch

        assert {:ok, recovered_remote_state} =
                 CodexResponsesSocket.handle_info(
                   {:websocket_owner_runtime_recovered, correlation_id, epoch, runtime},
                   remote_state
                 )

        refute recovered_remote_state.websocket_owner_lease_token ==
                 remote_state.websocket_owner_lease_token

        assert FakeUpstream.count(upstream) == 2
        assert [recovered_request] = request_logs(setup.pool.id)
        assert_owner_mode_accounting!(recovered_request, "lite", "succeeded", remote_node)

        assert recovered_turn =
                 Repo.one!(from(t in CodexTurn, where: t.request_id == ^recovered_request.id))

        assert recovered_turn.status == "succeeded"
        refute is_nil(recovered_turn.first_visible_output_at)

        assert {:push, {:text, recovered_frame}, recovered_remote_state} =
                 receive_owner_socket_push(recovered_remote_state)

        assert owner_response_id(recovered_frame) == "resp_owner_mode_kill_recovered"

        assert {:ok, recovered_remote_state} =
                 receive_owner_socket_complete(recovered_remote_state)

        active_correlation_id = active_downstream.correlation_id
        active_epoch = active_downstream.epoch

        refute_receive {:websocket_owner_frame, ^active_correlation_id, ^active_epoch, _payload},
                       100

        replacement_session = Repo.get!(CodexSession, state.codex_session.id)
        replacement_lease = active_owner_lease(state.codex_session.id)
        released_lease = Repo.get!(BridgeOwnerLease, old_lease.id)

        assert released_lease.status == "released"
        assert released_lease.metadata["release_reason"] == "owner_unavailable_takeover"
        assert replacement_lease.lease_token != old_lease.lease_token
        assert replacement_lease.lease_token == replacement_session.owner_lease_token

        assert recovered_remote_state.websocket_owner_lease_token ==
                 replacement_session.owner_lease_token

        assert recovered_remote_state.codex_session.owner_lease_token ==
                 replacement_session.owner_lease_token

        assert replacement_lease.owner_instance_id == replacement_session.owner_instance_id

        assert {:ok, replacement_owner_pid} =
                 WebsocketOwnerSession.lookup(state.codex_session.id)

        assert replacement_owner_pid != old_owner_pid

        replacement_owner_state = :sys.get_state(replacement_owner_pid)
        assert replacement_owner_state.owner_lease_token == replacement_lease.lease_token
        assert replacement_owner_state.downstream == active_downstream

        {:ok, next_state} =
          owner_socket(auth, "ws-owner-mode-kill-next", "owner-mode-kill")

        next_remote_state = remote_owner_state(next_state, remote_node, base_node_opts)

        try do
          assert :ok =
                   WebsocketOwnerNodeHarness.with_node_client(
                     [remote_node],
                     [
                       calls: %{remote_node => :success},
                       notify: self(),
                       capture_request_to: self()
                     ],
                     fn node_opts ->
                       Gateway.run_websocket_response(
                         auth,
                         model_serving_owner_payload(
                           setup,
                           "remote-owner-kill-next",
                           "client-true"
                         ),
                         owner_response_options(next_remote_state, node_opts),
                         fn _data -> :ok end
                       )
                     end
                   )

          assert_remote_submit_request_v1!(next_remote_state, remote_node, nil, 1_000)

          assert {:push, {:text, next_frame}, next_remote_state} =
                   receive_owner_socket_push(next_remote_state)

          assert owner_response_id(next_frame) == "resp_owner_mode_kill_next_turn"
          assert {:ok, _next_remote_state} = receive_owner_socket_complete(next_remote_state)
        after
          CodexResponsesSocket.terminate(:closed, next_remote_state)
        end

        assert [killed_lite_request, recovered_lite_request, full_request] =
                 await_upstream_requests(upstream, 3)

        assert_canonical_lite_owner_request!(killed_lite_request)
        assert_canonical_lite_owner_request!(recovered_lite_request)
        assert_canonical_full_owner_request!(full_request)

        assert [lite_request, full_request] = request_logs(setup.pool.id)
        assert lite_request.retry_count == 0
        assert_owner_mode_accounting!(lite_request, "lite", "succeeded", remote_node)
        assert_owner_mode_accounting!(full_request, "full", "succeeded", remote_node)

        assert active_owner_lease(state.codex_session.id).lease_token ==
                 replacement_lease.lease_token
      after
        send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

        if Process.alive?(interrupted_turn.pid) do
          Task.shutdown(interrupted_turn, :brutal_kill)
        end
      end
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  @tag :owner_crash_recovery
  @tag :replay_cleanup
  @tag :replay_topology
  test "remote owner process death after visible output remains terminal" do
    release_ref = make_ref()
    upstream_boundary = visible_blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-visible-kill", "owner-visible-kill",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    remote_node = :"codex_pooler@visible-killed-owner.example"

    node_opts =
      [upstream: upstream_boundary] ++
        WebsocketOwnerNodeHarness.node_client_opts([remote_node],
          calls: %{remote_node => :success}
        )

    remote_state = remote_owner_state(state, remote_node, node_opts)
    old_lease = active_owner_lease(state.codex_session.id)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    parent = self()

    try do
      visible_turn =
        Task.async(fn ->
          WebsocketOwnerNodeHarness.with_node_client(
            [remote_node],
            [calls: %{remote_node => :success}, notify: parent],
            fn harness_opts ->
              Gateway.run_websocket_response(
                auth,
                websocket_payload(setup, "visible owner crash"),
                owner_response_options(
                  remote_state,
                  [upstream: upstream_boundary] ++ harness_opts
                ),
                fn _data -> :ok end
              )
            end
          )
        end)

      assert_receive {:visible_blocking_owner_upstream, worker_pid, ^release_ref}, 1_000

      try do
        assert {:push, {:text, visible_frame}, _remote_state} =
                 receive_owner_socket_push(remote_state)

        assert owner_response_id(visible_frame) == "resp_owner_visible_before_crash"

        Process.exit(owner_pid, :kill)
        assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 1_000
        send(worker_pid, {:visible_blocking_owner_release, release_ref})

        assert {:error, %{code: "owner_crashed", status: 502}} =
                 Task.await(visible_turn, 3_000)

        assert {:error, :owner_unavailable} =
                 WebsocketOwnerSession.lookup(state.codex_session.id)

        assert active_owner_lease(state.codex_session.id).lease_token == old_lease.lease_token
        assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "active"
        assert FakeUpstream.count(upstream) == 0
      after
        send(worker_pid, {:visible_blocking_owner_release, release_ref})

        if Process.alive?(visible_turn.pid) do
          Task.shutdown(visible_turn, :brutal_kill)
        end
      end
    after
      CodexResponsesSocket.terminate(:closed, remote_state)
    end
  end

  test "malformed remote owner reply settles once as owner_crashed" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-malformed-reply", "owner-malformed-reply")
    remote_node = :"codex_pooler@malformed-reply-owner.example"
    private_owner_body = "private owner reply body"

    malformed_reply =
      {:ok,
       %{
         body: private_owner_body,
         terminal: "response.failed",
         status: 502,
         headers: %{}
       }}

    node_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => {:return, malformed_reply}},
        capture_request_to: self()
      )

    remote_state = remote_owner_state(state, remote_node, node_opts)

    alias_ids_before =
      Repo.all(
        from(alias_record in BridgeSessionAlias,
          where: alias_record.codex_session_id == ^remote_state.codex_session.id,
          select: alias_record.id,
          order_by: [asc: alias_record.id]
        )
      )

    logs =
      capture_stream_outcome_telemetry(fn ->
        logs =
          capture_log(fn ->
            try do
              assert {:error, %{code: "owner_crashed", status: 502}} =
                       Gateway.run_websocket_response(
                         auth,
                         websocket_payload(setup, "malformed owner reply"),
                         owner_response_options(remote_state, node_opts),
                         fn _data -> :ok end
                       )
            after
              # The forced malformed reply also reaches the remote detach call, so
              # terminate doubles as the detach-containment regression.
              assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
            end
          end)

        assert_receive {:stream_outcome,
                        %{
                          outcome: "failed",
                          downstream_transport: "websocket",
                          upstream_transport: "websocket"
                        }}

        refute_received {:stream_outcome, _metadata}
        logs
      end)

    refute logs =~ private_owner_body
    refute logs =~ "websocket response task failed"

    # Both containment boundaries announce themselves under the same classifying
    # key instead of silently masquerading as a real owner crash, so one query
    # finds both.
    assert logs =~
             "websocket owner reply malformed boundary=submit " <>
               "reply_shape=map_invalid_fields invalid=status,headers"

    assert logs =~
             "websocket owner reply malformed boundary=detach " <>
               "reply_shape=ok_tuple_with_value canonical_error=owner_crashed"

    assert [request] = request_logs(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.response_status_code == 502
    assert request.last_error_code == "owner_crashed"

    # The submit-boundary line must carry the same upgrade request id the rest
    # of the websocket log family uses, so the two can be joined.
    assert logs =~ "canonical_error=owner_crashed request_id=ws-owner-malformed-reply"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"

    assert [turn] =
             Repo.all(
               from(t in CodexTurn, where: t.codex_session_id == ^remote_state.codex_session.id)
             )

    assert turn.status == "failed"

    assert Repo.all(
             from(alias_record in BridgeSessionAlias,
               where: alias_record.codex_session_id == ^remote_state.codex_session.id,
               select: alias_record.id,
               order_by: [asc: alias_record.id]
             )
           ) == alias_ids_before

    assert FakeUpstream.count(upstream) == 0

    assert_remote_submit_request_v1!(remote_state, remote_node)
  end

  test "live owner-forwarded websocket keeps an accepted model miss on its established lane" do
    pinned_upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_live_anchor",
             "object" => "response",
             "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
           }),
           FakeUpstream.sse_stream(
             [
               {"response.failed",
                %{
                  "type" => "response.failed",
                  "response" => %{
                    "id" => "resp_owner_live_model_miss",
                    "error" => %{"code" => "model_not_found", "param" => "model"}
                  }
                }}
             ],
             done: false
           )
         ]}
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_live_fallback_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream, exposed_model_id: "gpt-example-luna")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-live-model-miss", "owner-live-model-miss")

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {websocket_payload(setup, "synthetic owner live anchor"), [opcode: :text]},
               state
             )

    [anchor_task_pid] = MapSet.to_list(state.tasks)
    assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
    assert %{"id" => "resp_owner_live_anchor"} = Jason.decode!(anchor_frame)
    assert {:ok, state} = receive_owner_socket_complete(state)
    assert {:ok, state} = acknowledge_response_task_delivery_if_pending(state, anchor_task_pid)
    assert {:ok, state} = receive_socket_done(state)
    assert MapSet.size(state.tasks) == 0

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-owner-live-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    _model = put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {websocket_payload(setup, "synthetic owner live model miss"), [opcode: :text]},
               state
             )

    [response_task_pid] = MapSet.to_list(state.tasks)

    assert_receive {:websocket_owner_output_commit_probe, _, _, ^response_task_pid, _, _, _} =
                     output_commit_probe,
                   @handoff_detection_timeout_ms

    assert {:ok, state} = CodexResponsesSocket.handle_info(output_commit_probe, state)

    assert {:push, {:text, failed_frame}, state} = receive_socket_push(state)
    assert %{"type" => "response.failed"} = Jason.decode!(failed_frame)
    assert MapSet.size(state.tasks) == 1
    assert {:ok, state} = acknowledge_response_task_delivery_if_pending(state, response_task_pid)

    assert FakeUpstream.count(pinned_upstream) == 2
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [anchor_request, failed_request] = request_logs(setup.pool.id)
    assert anchor_request.status == "succeeded"
    assert failed_request.status == "failed"
    assert failed_request.retry_count == 0

    assert [failed_attempt] =
             Repo.all(from(a in Attempt, where: a.request_id == ^failed_request.id))

    assert failed_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert failed_attempt.status == "failed"
    assert failed_attempt.usage_status == "usage_unknown"

    assert MapSet.size(state.tasks) == 0
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  @tag :feature_websocket_terminal_auth_refresh
  test "owner-forwarded websocket handshake 401 refreshes through the same owner without demotion" do
    initial_residency = "ws-owner-initial-region-#{System.unique_integer([:positive])}"
    refreshed_residency = "ws-owner-refreshed-region-#{System.unique_integer([:positive])}"
    initial_access_token = synthetic_access_token(initial_residency)
    refreshed_access_token = synthetic_access_token(refreshed_residency)

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_upgrade_error(
             %{"error" => %{"code" => "invalid_api_key"}},
             status: 401,
             headers: [{"x-openai-authorization-error", "invalid_api_key"}]
           ),
           FakeUpstream.json_response(
             %{"access_token" => refreshed_access_token},
             200
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_auth_handshake_retry_success",
             "object" => "response",
             "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
           })
         ]}
      )

    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "access_token",
               plaintext: initial_access_token
             })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "refresh-token-owner-ws-handshake-do-not-leak"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    telemetry_handler_id = attach_stream_outcome_telemetry!()
    on_exit(fn -> :telemetry.detach(telemetry_handler_id) end)

    {:ok, state} =
      owner_socket(auth, "ws-owner-auth-handshake-refresh", "owner-auth-handshake-refresh")

    try do
      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      {{:ok, state}, logs} =
        with_info_log(fn ->
          CodexResponsesSocket.handle_in(
            {websocket_payload(setup, "owner handshake auth refresh"), [opcode: :text]},
            state
          )
        end)

      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_auth_handshake_retry_success"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
      assert_receive {:stream_outcome, telemetry_metadata}
      refute inspect(telemetry_metadata) =~ initial_residency
      refute inspect(telemetry_metadata) =~ refreshed_residency
      refute inspect(telemetry_metadata) =~ initial_access_token
      refute inspect(telemetry_metadata) =~ refreshed_access_token
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert [refresh_request, retried_request] = await_upstream_requests(upstream, 2)
      assert refresh_request.path == "/oauth/token"
      assert retried_request.method == "WEBSOCKET"
      assert retried_request.path == "/backend-api/codex/responses"

      assert Map.new(retried_request.headers)["authorization"] ==
               "Bearer #{refreshed_access_token}"

      assert header_values(retried_request.headers, "x-openai-internal-codex-residency") == [
               refreshed_residency
             ]

      refute initial_residency in header_values(
               retried_request.headers,
               "x-openai-internal-codex-residency"
             )

      assert header_values(retried_request.headers, "chatgpt-account-id") == [
               setup.identity.chatgpt_account_id
             ]

      assert FakeUpstream.websocket_connection_count(upstream) == 1
      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 1
      assert request.last_error_code == nil
      assert request.request_metadata["auth_refresh"]["status"] == "succeeded"

      owner_metadata = request.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())
      refute Repo.exists?(from d in BridgeDemotion, where: d.pool_id == ^setup.pool.id)

      assert [first_attempt, second_attempt] =
               Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_unauthorized"
      assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert second_attempt.status == "succeeded"

      metadata_text =
        inspect(
          {request.request_metadata, first_attempt.response_metadata,
           second_attempt.response_metadata}
        )

      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "refresh-token-owner-ws-handshake-do-not-leak"
      refute metadata_text =~ initial_residency
      refute metadata_text =~ refreshed_residency
      refute metadata_text =~ initial_access_token
      refute metadata_text =~ refreshed_access_token
      refute metadata_text =~ "Bearer "

      assert_owner_websocket_values_not_persisted!(
        setup,
        [initial_residency, refreshed_residency, initial_access_token, refreshed_access_token],
        logs
      )
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "response.processed after reconnect is forwarded through the owner upstream connection" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_processed",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-processed-first",
          accepted_turn_state: "stable-ws-owner-processed",
          client_ip: "127.0.0.1"
        }
      })

    first_payload = websocket_payload(setup, "first processed owner turn")

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
    assert %{"id" => "resp_owner_processed"} = Jason.decode!(first_frame)
    assert {:ok, first_state} = receive_owner_socket_complete(first_state)
    assert {:ok, first_state} = receive_socket_done(first_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-processed-second",
          accepted_turn_state: "stable-ws-owner-processed",
          client_ip: "127.0.0.1"
        }
      })

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_processed"
        })

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, second_state)

      assert {:ok, second_state} = receive_owner_socket_complete(second_state)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [first_request, processed_request] = await_upstream_requests(upstream, 2)
      assert first_request.method == "WEBSOCKET"
      assert processed_request.method == "WEBSOCKET"
      assert first_request.websocket_connection_id == processed_request.websocket_connection_id

      assert processed_request.json == %{
               "type" => "response.processed",
               "response_id" => "resp_owner_processed"
             }
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner-forwarded immediate response create retargets socket owner runtime before spawning" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_immediate_retarget_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_immediate_retarget_success",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_state} = owner_socket(auth, "ws-owner-retarget-anchor", "retarget-target")

    anchor_payload =
      websocket_payload(setup, "owner retarget anchor", %{
        "request_id" => "ws-owner-retarget-anchor"
      })

    assert {:ok, target_state} =
             CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

    assert {:push, {:text, anchor_frame}, target_state} =
             receive_owner_socket_push(target_state)

    assert %{"id" => "resp_owner_immediate_retarget_anchor"} = Jason.decode!(anchor_frame)
    assert {:ok, target_state} = receive_socket_done(target_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, target_state)

    target_session = target_state.codex_session

    {:ok, origin_state} = owner_socket(auth, "ws-owner-retarget-origin", "retarget-origin")
    origin_session = origin_state.codex_session

    continuation_payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "owner retarget continuation"
          }
        ],
        "stream" => true,
        "generate" => true,
        "previous_response_id" => "resp_owner_immediate_retarget_anchor",
        "request_id" => "ws-owner-retarget-continuation"
      })

    assert {:ok, retargeted_state} =
             CodexResponsesSocket.handle_in(
               {continuation_payload, [opcode: :text]},
               origin_state
             )

    assert retargeted_state.codex_session.id == target_session.id
    refute retargeted_state.codex_session.id == origin_session.id
    assert retargeted_state.websocket_owner_lease_token == target_session.owner_lease_token
    assert retargeted_state.websocket_owner_downstream.epoch > 0

    assert {:push, {:text, retarget_frame}, retargeted_state} =
             receive_owner_socket_push(retargeted_state)

    assert %{"id" => "resp_owner_immediate_retarget_success"} = Jason.decode!(retarget_frame)
    assert {:ok, retargeted_state} = receive_socket_done(retargeted_state)

    assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)

    assert anchor_request.websocket_connection_id ==
             retargeted_request.websocket_connection_id

    assert retargeted_request.json["previous_response_id"] ==
             "resp_owner_immediate_retarget_anchor"

    assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
    assert anchor_log.status == "succeeded"
    assert retargeted_log.status == "succeeded"
    assert_native_turn_correlation!(retargeted_log.correlation_id)

    owner_metadata = retargeted_log.request_metadata["websocket_owner_forwarding"]
    assert owner_metadata["enabled"] == true
    assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
    assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

    assert :ok = CodexResponsesSocket.terminate(:closed, retargeted_state)
  end

  test "owner-forwarded response create retargets from frame turn-state before spawning" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_turn_state_retarget_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_turn_state_retarget_success",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    target_turn_state = "stable-ws-owner-frame-turn-state-retarget"
    origin_turn_state = "stable-ws-owner-frame-turn-state-origin"

    {:ok, target_state} =
      owner_socket(
        auth,
        "ws-owner-turn-state-retarget-anchor",
        target_turn_state
      )

    anchor_payload =
      websocket_payload(setup, "owner turn-state retarget anchor", %{
        "request_id" => "ws-owner-turn-state-retarget-anchor"
      })

    assert {:ok, target_state} =
             CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

    assert {:push, {:text, anchor_frame}, target_state} =
             receive_owner_socket_push(target_state)

    assert %{"id" => "resp_owner_turn_state_retarget_anchor"} = Jason.decode!(anchor_frame)
    assert {:ok, target_state} = receive_socket_done(target_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, target_state)

    target_session = target_state.codex_session
    {:ok, origin_state} = owner_socket(auth, "ws-owner-turn-state-origin", origin_turn_state)
    origin_session = origin_state.codex_session

    continuation_payload =
      websocket_payload(setup, "owner turn-state retarget continuation", %{
        "client_metadata" => %{"x-codex-turn-state" => target_turn_state},
        "request_id" => "ws-owner-turn-state-retarget-continuation"
      })

    assert {:ok, retargeted_state} =
             CodexResponsesSocket.handle_in(
               {continuation_payload, [opcode: :text]},
               origin_state
             )

    assert retargeted_state.codex_session.id == target_session.id
    refute retargeted_state.codex_session.id == origin_session.id
    assert retargeted_state.websocket_owner_lease_token == target_session.owner_lease_token
    assert retargeted_state.websocket_owner_downstream.epoch > 0

    assert {:push, {:text, retarget_frame}, retargeted_state} =
             receive_owner_socket_push(retargeted_state)

    assert %{"id" => "resp_owner_turn_state_retarget_success"} = Jason.decode!(retarget_frame)
    assert {:ok, retargeted_state} = receive_socket_done(retargeted_state)

    assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)

    assert anchor_request.websocket_connection_id ==
             retargeted_request.websocket_connection_id

    assert retargeted_request.json["client_metadata"]["x-codex-turn-state"] ==
             target_turn_state

    assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
    assert anchor_log.status == "succeeded"
    assert retargeted_log.status == "succeeded"
    assert_native_turn_correlation!(retargeted_log.correlation_id)
    assert retargeted_log.request_metadata["codex_session_id"] == target_session.id

    owner_metadata = retargeted_log.request_metadata["websocket_owner_forwarding"]
    assert owner_metadata["enabled"] == true
    assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
    assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

    refute_raw_turn_state_session_key!(setup.pool.id, origin_turn_state)
    refute_raw_turn_state_session_key!(setup.pool.id, target_turn_state)
    assert_no_leak_in_persistence!(setup.pool.id)

    assert :ok = CodexResponsesSocket.terminate(:closed, retargeted_state)
  end

  test "owner-forwarded retarget ignores stale origin downstream and cleans up target owner" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_retarget_cleanup_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_retarget_cleanup_success",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_state} =
      owner_socket(auth, "ws-owner-retarget-cleanup-anchor", "retarget-cleanup-target")

    target_state =
      try do
        anchor_payload =
          websocket_payload(setup, "owner retarget cleanup anchor", %{
            "request_id" => "ws-owner-retarget-cleanup-anchor"
          })

        assert {:ok, target_state} =
                 CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, target_state)

        assert {:push, {:text, anchor_frame}, target_state} =
                 receive_owner_socket_push(target_state)

        assert %{"id" => "resp_owner_retarget_cleanup_anchor"} = Jason.decode!(anchor_frame)
        assert {:ok, target_state} = receive_socket_done(target_state)
        target_state
      after
        CodexResponsesSocket.terminate(:closed, target_state)
      end

    target_session = target_state.codex_session
    {:ok, target_owner_pid} = WebsocketOwnerSession.lookup(target_session.id)
    assert %{downstream: nil} = :sys.get_state(target_owner_pid)

    {:ok, origin_state} =
      owner_socket(auth, "ws-owner-retarget-cleanup-origin", "retarget-cleanup-origin")

    origin_session = origin_state.codex_session
    origin_downstream = origin_state.websocket_owner_downstream
    {:ok, origin_owner_pid} = WebsocketOwnerSession.lookup(origin_session.id)

    retargeted_state =
      try do
        continuation_payload =
          websocket_payload(setup, "owner retarget cleanup continuation", %{
            "previous_response_id" => "resp_owner_retarget_cleanup_anchor",
            "request_id" => "ws-owner-retarget-cleanup-continuation"
          })

        assert {:ok, retargeted_state} =
                 CodexResponsesSocket.handle_in(
                   {continuation_payload, [opcode: :text]},
                   origin_state
                 )

        assert retargeted_state.codex_session.id == target_session.id
        refute retargeted_state.codex_session.id == origin_session.id
        assert retargeted_state.websocket_owner_lease_token == target_session.owner_lease_token
        assert retargeted_state.websocket_owner_downstream.epoch > 0
        assert :sys.get_state(origin_owner_pid).downstream == origin_downstream

        assert :sys.get_state(target_owner_pid).downstream ==
                 retargeted_state.websocket_owner_downstream

        {retargeted_state, stale_logs} =
          with_log([level: :warning], fn ->
            assert_stale_owner_downstream_ignored(
              origin_owner_pid,
              origin_downstream,
              retargeted_state
            )
          end)

        assert stale_logs == ""
        assert_no_leak!("stale origin downstream logs", stale_logs)

        assert {:push, {:text, retarget_frame}, retargeted_state} =
                 receive_owner_socket_push(retargeted_state)

        assert %{"id" => "resp_owner_retarget_cleanup_success"} = Jason.decode!(retarget_frame)
        assert {:ok, retargeted_state} = receive_socket_done(retargeted_state)
        retargeted_state
      after
        {_, origin_cleanup_logs} =
          with_log([level: :warning], fn ->
            assert :ok = CodexResponsesSocket.terminate(:closed, origin_state)
          end)

        assert origin_cleanup_logs == ""
        assert_no_leak!("stale origin cleanup logs", origin_cleanup_logs)
      end

    {_, target_cleanup_logs} =
      with_log([level: :warning], fn ->
        assert :ok = CodexResponsesSocket.terminate(:closed, retargeted_state)
      end)

    assert target_cleanup_logs == ""
    assert_no_leak!("retarget cleanup logs", target_cleanup_logs)
    assert %{downstream: nil} = :sys.get_state(target_owner_pid)
    assert [anchor_request, retargeted_request] = await_upstream_requests(upstream, 2)
    assert anchor_request.websocket_connection_id == retargeted_request.websocket_connection_id

    assert [anchor_log, retargeted_log] = request_logs(setup.pool.id)
    assert anchor_log.status == "succeeded"
    assert retargeted_log.status == "succeeded"
    assert_native_turn_correlation!(retargeted_log.correlation_id)
    refute inspect(request_logs(setup.pool.id)) =~ "owner_unavailable"
    refute inspect(request_logs(setup.pool.id)) =~ "owner_drained"
  end

  test "owner-forwarded retarget keeps the current runtime for a cross-pool alias cache miss before the generation guard" do
    origin_upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    target_upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    origin_setup = gateway_setup(origin_upstream)
    target_setup = gateway_setup(target_upstream)
    previous_response_id = "#{@sentinel}-cross-pool-alias"

    {:ok, origin_auth} = Access.authenticate_authorization_header(origin_setup.authorization)
    {:ok, target_auth} = Access.authenticate_authorization_header(target_setup.authorization)

    {:ok, target_state} =
      owner_socket(target_auth, "ws-owner-cross-scope-target", "cross-scope-target")

    try do
      ensure_previous_response_alias!(
        target_state.codex_session,
        target_setup.api_key,
        previous_response_id
      )
    after
      CodexResponsesSocket.terminate(:closed, target_state)
    end

    {:ok, origin_state} =
      owner_socket(origin_auth, "ws-owner-cross-scope-origin", "cross-scope-origin")

    origin_session = origin_state.codex_session
    origin_lease_token = origin_state.websocket_owner_lease_token
    origin_downstream = origin_state.websocket_owner_downstream

    try do
      payload =
        websocket_payload(origin_setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-cross-scope-refused"
        })

      {retarget_admitted_state, logs} =
        with_log([level: :warning], fn ->
          assert {:ok, retarget_admitted_state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, origin_state)

          assert retarget_admitted_state.codex_session.id == origin_session.id
          assert retarget_admitted_state.websocket_owner_lease_token == origin_lease_token
          assert retarget_admitted_state.websocket_owner_downstream == origin_downstream

          assert {:ok, retarget_admitted_state} = receive_socket_done(retarget_admitted_state)

          retarget_admitted_state
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert retarget_admitted_state.codex_session.id == origin_session.id
      assert retarget_admitted_state.websocket_owner_lease_token == origin_lease_token
      assert retarget_admitted_state.websocket_owner_downstream == origin_downstream
      assert {:ok, _origin_owner_pid} = WebsocketOwnerSession.lookup(origin_session.id)

      assert {:ok, _target_owner_pid} =
               WebsocketOwnerSession.lookup(target_state.codex_session.id)

      assert FakeUpstream.count(origin_upstream) == 0
      assert FakeUpstream.count(target_upstream) == 0
      assert FakeUpstream.websocket_connection_count(origin_upstream) == 1
      assert FakeUpstream.websocket_connection_count(target_upstream) == 0
      assert [guarded_request] = request_logs(origin_setup.pool.id)
      assert guarded_request.status == "failed"
      assert guarded_request.last_error_code == "stream_incomplete"

      assert [guarded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^guarded_request.id))

      assert guarded_attempt.response_metadata["transport_failure"]["termination_source"] ==
               "continuation_generation_guard"

      assert [] = request_logs(target_setup.pool.id)
      assert_no_leak_in_persistence!(origin_setup.pool.id)
      assert_no_leak_in_persistence!(target_setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, origin_state)
    end
  end

  test "owner-forwarded retarget keeps the current runtime for an expired alias cache miss before the generation guard" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    previous_response_id = "#{@sentinel}-stale-alias"

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-stale-alias", "stale-alias-origin")
    session = state.codex_session
    lease_token = state.websocket_owner_lease_token
    downstream = state.websocket_owner_downstream

    stale_alias = ensure_previous_response_alias!(session, setup.api_key, previous_response_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    stale_alias
    |> BridgeSessionAlias.changeset(%{
      status: "expired",
      expires_at: DateTime.add(now, -1, :second),
      updated_at: now
    })
    |> Repo.update!()

    try do
      payload =
        websocket_payload(setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-stale-alias-refused"
        })

      {retarget_admitted_state, logs} =
        with_log([level: :warning], fn ->
          assert {:ok, retarget_admitted_state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

          assert retarget_admitted_state.codex_session.id == session.id
          assert retarget_admitted_state.websocket_owner_lease_token == lease_token
          assert retarget_admitted_state.websocket_owner_downstream == downstream

          assert {:ok, retarget_admitted_state} = receive_socket_done(retarget_admitted_state)

          retarget_admitted_state
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert retarget_admitted_state.codex_session.id == session.id
      assert retarget_admitted_state.websocket_owner_lease_token == lease_token
      assert retarget_admitted_state.websocket_owner_downstream == downstream
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [guarded_request] = request_logs(setup.pool.id)
      assert guarded_request.status == "failed"
      assert guarded_request.last_error_code == "stream_incomplete"

      assert [guarded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^guarded_request.id))

      assert guarded_attempt.response_metadata["transport_failure"]["termination_source"] ==
               "continuation_generation_guard"

      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :continuation_generation_boundary
  test "owner-forwarded alias cache miss forwards unchanged on the reused current connection" do
    previous_response_id = "#{@sentinel}-reused-alias-miss"

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_reused_alias_miss_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_reused_alias_miss_continuation",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-reused-alias-miss", "reused-alias-miss")

    try do
      anchor_payload =
        websocket_payload(setup, "owner reused alias miss anchor", %{
          "request_id" => "ws-owner-reused-alias-miss-anchor"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, state)

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(anchor_frame) == "resp_owner_reused_alias_miss_anchor"
      assert {:ok, state} = receive_socket_done(state)

      continuation_payload =
        websocket_payload(setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-reused-alias-miss-continuation"
        })

      {_state, logs} =
        with_info_log(fn ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in({continuation_payload, [opcode: :text]}, state)

          assert {:push, {:text, continuation_frame}, state} = receive_owner_socket_push(state)

          assert owner_response_id(continuation_frame) ==
                   "resp_owner_reused_alias_miss_continuation"

          assert {:ok, state} = receive_socket_done(state)
          state
        end)

      assert logs =~ "websocket owner retarget alias miss"
      assert logs =~ "alias_kind=previous_response_id"
      assert logs =~ "outcome=current_runtime"
      assert logs =~ "request_id=ws-owner-reused-alias-miss"
      assert logs =~ "codex_session_id=#{state.codex_session.id}"
      assert logs =~ "owner_instance_id=#{state.codex_session.owner_instance_id}"
      assert logs =~ "proxy_instance_id=#{node()}"
      refute logs =~ previous_response_id
      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert_no_leak!("reused alias miss logs", logs)

      assert FakeUpstream.count(upstream) == 2
      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [anchor_request, continuation_request] = await_upstream_requests(upstream, 2)

      assert anchor_request.websocket_connection_id ==
               continuation_request.websocket_connection_id

      assert continuation_request.json["previous_response_id"] == previous_response_id

      assert [anchor_log, continuation_log] = request_logs(setup.pool.id)
      assert anchor_log.status == "succeeded"
      assert continuation_log.status == "succeeded"
      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :continuation_generation_boundary
  test "owner-forwarded alias cache miss guards a replacement connection then reuses it for a full request" do
    previous_response_id = "#{@sentinel}-replacement-alias-miss"

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_replacement_alias_miss_anchor",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_replacement_alias_miss_full_retry",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-replacement-alias-miss", "replacement-alias-miss")

    try do
      anchor_payload =
        websocket_payload(setup, "owner replacement alias miss anchor", %{
          "request_id" => "ws-owner-replacement-alias-miss-anchor"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, state)

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(anchor_frame) == "resp_owner_replacement_alias_miss_anchor"
      assert {:ok, state} = receive_socket_done(state)

      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      upstream_pid = :sys.get_state(owner_pid).upstream_pid
      assert :ok = UpstreamWebsocketSession.invalidate_connection(upstream_pid)

      continuation_payload =
        websocket_payload(setup, @sentinel, %{
          "previous_response_id" => previous_response_id,
          "request_id" => "ws-owner-replacement-alias-miss-continuation"
        })

      {state, logs} =
        with_log([level: :warning], fn ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in({continuation_payload, [opcode: :text]}, state)

          assert {:push, {:text, guard_terminal}, state} = receive_owner_socket_push(state)
          assert Jason.decode!(guard_terminal) == Jason.decode!(native_owner_retry_terminal())
          assert {:ok, state} = receive_socket_done(state)
          refute_received {:websocket_owner_frame, _, _, {:data, ^guard_terminal}}
          state
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"
      assert_no_leak!("replacement alias miss logs", logs)

      assert FakeUpstream.count(upstream) == 1
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [anchor_request, guarded_request] = request_logs(setup.pool.id)
      assert anchor_request.status == "succeeded"
      assert guarded_request.status == "failed"
      assert guarded_request.last_error_code == "stream_incomplete"

      assert [guarded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^guarded_request.id))

      assert guarded_attempt.status == "failed"
      assert guarded_attempt.network_error_code == "stream_incomplete"

      assert guarded_attempt.response_metadata["transport_failure"] == %{
               "connection_use" => "reconnected",
               "phase" => "send_payload",
               "pre_visible_output" => true,
               "reason" => "previous_response_generation_mismatch",
               "reason_class" => "previous_response_generation_mismatch",
               "termination_source" => "continuation_generation_guard",
               "terminal_seen" => false,
               "text_frame_count" => 0,
               "upstream_committed" => false
             }

      assert %{
               "generation" => 2,
               "reconnected" => true,
               "reused" => false
             } = guarded_attempt.response_metadata["upstream_websocket_connection"]

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where:
                   entry.request_id == ^guarded_request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(bridge_alias in BridgeSessionAlias,
                 where:
                   bridge_alias.pool_id == ^setup.pool.id and
                     bridge_alias.api_key_id == ^setup.api_key.id and
                     bridge_alias.alias_kind == "previous_response_id" and
                     bridge_alias.alias_hash == ^:crypto.hash(:sha256, previous_response_id)
               ),
               :count
             ) == 0

      full_retry_payload =
        websocket_payload(setup, "owner replacement alias miss full retry", %{
          "request_id" => "ws-owner-replacement-alias-miss-full-retry"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({full_retry_payload, [opcode: :text]}, state)

      assert {:push, {:text, full_retry_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(full_retry_frame) == "resp_owner_replacement_alias_miss_full_retry"
      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.count(upstream) == 2
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [anchor_upstream_request, full_retry_upstream_request] =
               await_upstream_requests(upstream, 2)

      assert anchor_upstream_request.websocket_connection_id !=
               full_retry_upstream_request.websocket_connection_id

      refute Map.has_key?(full_retry_upstream_request.json, "previous_response_id")

      assert [^anchor_request, ^guarded_request, full_retry_request] = request_logs(setup.pool.id)
      assert full_retry_request.status == "succeeded"

      assert [full_retry_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^full_retry_request.id))

      assert %{
               "generation" => 2,
               "reconnected" => false,
               "reused" => true
             } = full_retry_attempt.response_metadata["upstream_websocket_connection"]

      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded retarget keeps the current runtime for guessed and cross-key alias cache misses" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    alternate_key = CodexPooler.PoolerFixtures.api_key_fixture(setup.pool)
    previous_response_id = "#{@sentinel}-cross-key-alias"

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, alternate_auth} = Access.authenticate_authorization_header(alternate_key.authorization)
    {:ok, origin_state} = owner_socket(auth, "ws-owner-cache-miss-origin", "cache-miss-origin")

    {:ok, target_state} =
      owner_socket(alternate_auth, "ws-owner-cache-miss-target", "cache-miss-target")

    origin_session = origin_state.codex_session
    origin_lease_token = origin_state.websocket_owner_lease_token
    origin_downstream = origin_state.websocket_owner_downstream

    try do
      ensure_previous_response_alias!(
        target_state.codex_session,
        alternate_key.api_key,
        previous_response_id
      )

      {returned_runtimes, logs} =
        with_log([level: :warning], fn ->
          for alias_miss <- ["#{@sentinel}-guessed-alias", previous_response_id] do
            assert {:ok, returned_runtime} =
                     Gateway.retarget_websocket_owner_runtime(auth, origin_state, %{
                       "type" => "response.create",
                       "previous_response_id" => alias_miss
                     })

            returned_runtime
          end
        end)

      refute logs =~ "owner_unavailable"
      refute logs =~ "status=503"

      for returned_runtime <- returned_runtimes do
        assert returned_runtime.codex_session.id == origin_session.id
        assert returned_runtime.websocket_owner_lease_token == origin_lease_token
        assert returned_runtime.websocket_owner_downstream == origin_downstream
      end

      assert {:ok, _origin_owner_pid} = WebsocketOwnerSession.lookup(origin_session.id)

      assert {:ok, _target_owner_pid} =
               WebsocketOwnerSession.lookup(target_state.codex_session.id)

      assert FakeUpstream.count(upstream) == 0
      assert [] = request_logs(setup.pool.id)
      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, origin_state)
      CodexResponsesSocket.terminate(:closed, target_state)
    end
  end

  test "tool-output continuation after reconnect is forwarded through the owner" do
    first_submission_ref = make_ref()
    second_submission_ref = make_ref()

    refute first_submission_ref == second_submission_ref

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream(
             [%{"id" => "resp_owner_tool_first", "object" => "response"}],
             barrier_after: 0,
             notify: self(),
             release_ref: first_submission_ref
           ),
           FakeUpstream.barrier_sse_stream(
             [%{"id" => "resp_owner_tool_second", "object" => "response"}],
             barrier_after: 0,
             notify: self(),
             release_ref: second_submission_ref
           )
         ]}
      )

    setup = gateway_setup(upstream, supported_compression_model_opts())
    enable_request_compression!(setup.pool)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-tool-first",
          accepted_turn_state: "stable-ws-owner-tool",
          client_ip: "127.0.0.1"
        }
      })

    first_payload = websocket_payload(setup, "first owner tool turn")

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:fake_upstream_chunk_barrier, 0, first_upstream_pid, ^first_submission_ref},
                   5_000

    assert [first_request] = FakeUpstream.requests(upstream)
    refute Map.has_key?(first_request.json, "previous_response_id")

    send(first_upstream_pid, {:fake_upstream_release_chunk, first_submission_ref})

    assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
    assert %{"id" => "resp_owner_tool_first"} = Jason.decode!(first_frame)
    assert {:ok, first_state} = receive_owner_socket_complete(first_state)
    assert {:ok, first_state} = receive_socket_done(first_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-tool-second",
          accepted_turn_state: "stable-ws-owner-tool",
          client_ip: "127.0.0.1"
        }
      })

    try do
      schema_bound_output = Jason.encode!(%{"rows" => Enum.to_list(1..160)}, pretty: true)
      unbound_output = Jason.encode!(%{"rows" => Enum.to_list(161..320)}, pretty: true)

      assert byte_size(schema_bound_output) > 512
      assert byte_size(unbound_output) > 512

      tool_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "tools" => [
            %{
              "type" => "function",
              "name" => "schema_bound_owner_fixture",
              "output_schema" => %{"type" => "object"}
            },
            %{"type" => "function", "name" => "unbound_owner_fixture"}
          ],
          "input" => [
            %{
              "type" => "function_call",
              "call_id" => "call_owner_schema_bound",
              "name" => "schema_bound_owner_fixture",
              "arguments" => "{}"
            },
            %{
              "type" => "function_call",
              "call_id" => "call_owner_unbound",
              "name" => "unbound_owner_fixture",
              "arguments" => "{}"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_owner_schema_bound",
              "output" => schema_bound_output
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_owner_unbound",
              "output" => unbound_output
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_owner_tool_first"
        })

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, second_state)

      assert_receive {:fake_upstream_chunk_barrier, 0, second_upstream_pid,
                      ^second_submission_ref},
                     5_000

      assert second_upstream_pid == first_upstream_pid

      assert [^first_request, second_request] = FakeUpstream.requests(upstream)
      assert second_request.json["previous_response_id"] == "resp_owner_tool_first"

      send(second_upstream_pid, {:fake_upstream_release_chunk, second_submission_ref})

      assert {:push, {:text, second_frame}, second_state} =
               receive_owner_socket_push(second_state)

      assert %{"id" => "resp_owner_tool_second"} = Jason.decode!(second_frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [^first_request, ^second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_owner_tool_first"

      schema_bound_item =
        Enum.find(second_request.json["input"], fn item ->
          item["type"] == "function_call_output" and
            item["call_id"] == "call_owner_schema_bound"
        end)

      unbound_item =
        Enum.find(second_request.json["input"], fn item ->
          item["type"] == "function_call_output" and item["call_id"] == "call_owner_unbound"
        end)

      assert schema_bound_item["output"] == schema_bound_output
      assert Jason.decode!(schema_bound_item["output"]) == Jason.decode!(schema_bound_output)
      assert unbound_item["output"] != unbound_output
      assert Jason.decode!(unbound_item["output"]) == Jason.decode!(unbound_output)

      assert [first_log, second_log] = request_logs(setup.pool.id)
      assert first_log.status == "succeeded"
      assert second_log.status == "succeeded"

      second_attempt =
        Repo.one!(
          from(a in Attempt,
            where: a.request_id == ^second_log.id,
            order_by: [asc: a.attempt_number]
          )
        )

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "compressed",
               "route_class" => "proxy_websocket",
               "transport" => "websocket",
               "candidate_count" => 1,
               "compressed_count" => 1,
               "skipped_count" => 0,
               "protected_tool_output_skipped_count" => 1
             } = second_attempt.response_metadata["payload_compression"]

      owner_metadata = second_log.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert is_integer(owner_metadata["downstream_epoch"])
      assert owner_metadata["downstream_epoch"] > 0
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())
      refute inspect(second_log.request_metadata) =~ "lease-token"

      refute_payload_compression_leak!(
        second_attempt.response_metadata["payload_compression"],
        ["call_owner_schema_bound", "call_owner_unbound"]
      )
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner-forwarded processed ack followed by tool continuation records three succeeded websocket rows" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_chain_first",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{"id" => "resp_owner_chain_tool", "object" => "response"})
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-chain"

    {:ok, first_state} = owner_socket(auth, "ws-owner-chain-first", turn_state)

    try do
      first_payload =
        websocket_payload(setup, "first owner chained turn", %{
          "request_id" => "ws-owner-chain-first"
        })

      assert {:ok, first_state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

      assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
      assert %{"id" => "resp_owner_chain_first"} = Jason.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, processed_state} = owner_socket(auth, "ws-owner-chain-processed", turn_state)

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_chain_first",
          "request_id" => "ws-owner-chain-processed"
        })

      assert {:ok, processed_state} =
               CodexResponsesSocket.handle_in(
                 {processed_payload, [opcode: :text]},
                 processed_state
               )

      assert {:ok, _processed_state} = receive_socket_done(processed_state)
    after
      CodexResponsesSocket.terminate(:closed, processed_state)
    end

    {:ok, tool_state} = owner_socket(auth, "ws-owner-chain-tool", turn_state)

    try do
      tool_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_owner_chain_tool",
              "output" => "owner chain tool output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_owner_chain_first",
          "request_id" => "ws-owner-chain-tool"
        })

      assert {:ok, tool_state} =
               CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, tool_state)

      assert {:push, {:text, tool_frame}, tool_state} = receive_owner_socket_push(tool_state)
      assert %{"id" => "resp_owner_chain_tool"} = Jason.decode!(tool_frame)
      assert {:ok, _tool_state} = receive_socket_done(tool_state)
    after
      CodexResponsesSocket.terminate(:closed, tool_state)
    end

    assert [first_request, processed_request, tool_request] = await_upstream_requests(upstream, 3)
    assert first_request.websocket_connection_id == processed_request.websocket_connection_id
    assert processed_request.websocket_connection_id == tool_request.websocket_connection_id
    assert processed_request.json["type"] == "response.processed"
    assert tool_request.json["previous_response_id"] == "resp_owner_chain_first"

    assert [first_log, processed_log, tool_log] = request_logs(setup.pool.id)

    assert_native_turn_correlation!(first_log.correlation_id)
    assert processed_log.correlation_id == "ws-owner-chain-processed"
    assert_native_request_correlation!(tool_log.correlation_id)
    refute first_log.correlation_id == tool_log.correlation_id

    assert Enum.all?([first_log, processed_log, tool_log], &(&1.status == "succeeded"))
    assert Enum.all?([first_log, processed_log, tool_log], &(&1.transport == "websocket"))
    assert Enum.all?([first_log, processed_log, tool_log], &(&1.response_status_code == 200))

    for request_log <- [first_log, processed_log, tool_log] do
      owner_metadata = request_log.request_metadata["websocket_owner_forwarding"]
      assert owner_metadata["enabled"] == true
      assert is_integer(owner_metadata["downstream_epoch"])
      assert owner_metadata["owner_instance_id"] == Atom.to_string(node())
      assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())
    end
  end

  test "owner-forwarded socket queues processed and tool continuation frames sent back to back" do
    release_ref = make_ref()
    upstream_boundary = chained_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-queued-chain"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-queue-first", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    try do
      first_payload =
        websocket_payload(setup, "first owner queued turn", %{
          "request_id" => "ws-owner-queue-first"
        })

      assert {:ok, first_state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

      assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
      assert %{"id" => "resp_owner_queue_first"} = Jason.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)

      ensure_previous_response_alias!(
        first_state.codex_session,
        setup.api_key,
        "resp_owner_queue_first"
      )
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, queued_state} = owner_socket(auth, "ws-owner-queue-processed", turn_state)

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_queue_first",
          "request_id" => "ws-owner-queue-processed"
        })

      tool_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_owner_queue_tool",
              "output" => "owner queue tool output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_owner_queue_first",
          "request_id" => "ws-owner-queue-tool"
        })

      assert {:ok, queued_state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, queued_state)

      assert_receive {:chained_owner_upstream_processed_blocked, processed_pid, ^release_ref}

      assert {:ok, queued_state} =
               CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, queued_state)

      assert MapSet.size(queued_state.tasks) == 1
      assert :queue.len(Map.get(queued_state, :queued_response_payloads, :queue.new())) == 1
      refute_received {:chained_owner_upstream_tool_started, ^release_ref}

      send(processed_pid, {:chained_owner_upstream_release, release_ref})
      assert {:ok, queued_state} = receive_socket_done(queued_state)

      assert_receive {:chained_owner_upstream_tool_started, ^release_ref},
                     @queued_owner_upstream_start_timeout_ms

      assert {:push, {:text, tool_frame}, queued_state} = receive_owner_socket_push(queued_state)
      assert %{"id" => "resp_owner_queue_tool"} = Jason.decode!(tool_frame)
      assert {:ok, _queued_state} = receive_socket_done(queued_state)
    after
      CodexResponsesSocket.terminate(:closed, queued_state)
    end

    assert [first_log, processed_log, tool_log] = request_logs(setup.pool.id)

    assert_native_turn_correlation!(first_log.correlation_id)
    assert processed_log.correlation_id == "ws-owner-queue-processed"
    assert_native_request_correlation!(tool_log.correlation_id)
    refute first_log.correlation_id == tool_log.correlation_id

    assert Enum.all?([first_log, processed_log, tool_log], &(&1.status == "succeeded"))
    assert Enum.all?([first_log, processed_log, tool_log], &(&1.response_status_code == 200))
  end

  test "queued owner-forwarded continuations retarget only when popped to start" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_anchor_a",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_anchor_b",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_a",
             "object" => "response"
           }),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_queue_alias_b",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, target_a_state} =
      owner_socket(auth, "ws-owner-queue-alias-anchor-a", "queue-alias-target-a")

    target_a_session =
      try do
        anchor_a_payload =
          websocket_payload(setup, "owner queue alias anchor a", %{
            "request_id" => "ws-owner-queue-alias-anchor-a"
          })

        assert {:ok, target_a_state} =
                 CodexResponsesSocket.handle_in(
                   {anchor_a_payload, [opcode: :text]},
                   target_a_state
                 )

        assert {:push, {:text, anchor_a_frame}, target_a_state} =
                 receive_owner_socket_push(target_a_state)

        assert %{"id" => "resp_owner_queue_alias_anchor_a"} = Jason.decode!(anchor_a_frame)
        assert {:ok, _target_a_state} = receive_socket_done(target_a_state)

        ensure_previous_response_alias!(
          target_a_state.codex_session,
          setup.api_key,
          "resp_owner_queue_alias_anchor_a"
        )

        target_a_state.codex_session
      after
        CodexResponsesSocket.terminate(:closed, target_a_state)
      end

    {:ok, target_b_state} =
      owner_socket(auth, "ws-owner-queue-alias-anchor-b", "queue-alias-target-b")

    target_b_session =
      try do
        anchor_b_payload =
          websocket_payload(setup, "owner queue alias anchor b", %{
            "request_id" => "ws-owner-queue-alias-anchor-b"
          })

        assert {:ok, target_b_state} =
                 CodexResponsesSocket.handle_in(
                   {anchor_b_payload, [opcode: :text]},
                   target_b_state
                 )

        assert {:push, {:text, anchor_b_frame}, target_b_state} =
                 receive_owner_socket_push(target_b_state)

        assert %{"id" => "resp_owner_queue_alias_anchor_b"} = Jason.decode!(anchor_b_frame)
        assert {:ok, _target_b_state} = receive_socket_done(target_b_state)

        ensure_previous_response_alias!(
          target_b_state.codex_session,
          setup.api_key,
          "resp_owner_queue_alias_anchor_b"
        )

        target_b_state.codex_session
      after
        CodexResponsesSocket.terminate(:closed, target_b_state)
      end

    {:ok, origin_state} =
      owner_socket(auth, "ws-owner-queue-alias-active", "queue-alias-origin",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    origin_session = origin_state.codex_session
    origin_lease_token = origin_state.websocket_owner_lease_token
    origin_downstream = origin_state.websocket_owner_downstream

    {queued_a_state, queued_b_state} =
      try do
        active_payload =
          websocket_payload(setup, "owner queue alias active", %{
            "request_id" => "ws-owner-queue-alias-active"
          })

        queued_a_payload =
          websocket_payload(setup, "owner queue alias continuation a", %{
            "previous_response_id" => "resp_owner_queue_alias_anchor_a",
            "request_id" => "ws-owner-queue-alias-a"
          })

        queued_b_payload =
          websocket_payload(setup, "owner queue alias continuation b", %{
            "previous_response_id" => "resp_owner_queue_alias_anchor_b",
            "request_id" => "ws-owner-queue-alias-b"
          })

        assert {:ok, origin_state} =
                 CodexResponsesSocket.handle_in({active_payload, [opcode: :text]}, origin_state)

        active_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

        assert {:ok, origin_state} =
                 CodexResponsesSocket.handle_in({queued_a_payload, [opcode: :text]}, origin_state)

        assert origin_state.codex_session.id == origin_session.id
        assert origin_state.websocket_owner_lease_token == origin_lease_token
        assert origin_state.websocket_owner_downstream == origin_downstream
        assert MapSet.size(origin_state.tasks) == 1
        assert :queue.len(Map.get(origin_state, :queued_response_payloads, :queue.new())) == 1

        assert {:ok, origin_state} =
                 CodexResponsesSocket.handle_in({queued_b_payload, [opcode: :text]}, origin_state)

        assert origin_state.codex_session.id == origin_session.id
        assert origin_state.websocket_owner_lease_token == origin_lease_token
        assert origin_state.websocket_owner_downstream == origin_downstream
        assert MapSet.size(origin_state.tasks) == 1
        assert :queue.len(Map.get(origin_state, :queued_response_payloads, :queue.new())) == 2
        assert length(FakeUpstream.requests(upstream)) == 2

        send(active_worker_pid, {:blocking_owner_upstream_release, release_ref})
        assert {:ok, queued_a_state} = receive_socket_done(origin_state)
        assert queued_a_state.codex_session.id == target_a_session.id
        refute queued_a_state.codex_session.id == origin_session.id
        assert :queue.len(Map.get(queued_a_state, :queued_response_payloads, :queue.new())) == 1

        assert {:push, {:text, queued_a_frame}, queued_a_state} =
                 receive_owner_socket_push(queued_a_state)

        assert %{"id" => "resp_owner_queue_alias_a"} = Jason.decode!(queued_a_frame)
        assert {:ok, queued_b_state} = receive_socket_done(queued_a_state)
        assert queued_b_state.codex_session.id == target_b_session.id
        refute queued_b_state.codex_session.id == target_a_session.id
        refute queued_b_state.codex_session.id == origin_session.id

        assert {:push, {:text, queued_b_frame}, queued_b_state} =
                 receive_owner_socket_push(queued_b_state)

        assert %{"id" => "resp_owner_queue_alias_b"} = Jason.decode!(queued_b_frame)
        assert {:ok, queued_b_state} = receive_socket_done(queued_b_state)

        {queued_a_state, queued_b_state}
      after
        CodexResponsesSocket.terminate(:closed, origin_state)
      end

    CodexResponsesSocket.terminate(:closed, queued_a_state)
    CodexResponsesSocket.terminate(:closed, queued_b_state)

    assert [anchor_a_request, anchor_b_request, queued_a_request, queued_b_request] =
             await_upstream_requests(upstream, 4)

    assert anchor_a_request.websocket_connection_id == queued_a_request.websocket_connection_id
    assert anchor_b_request.websocket_connection_id == queued_b_request.websocket_connection_id

    assert queued_a_request.json["previous_response_id"] ==
             "resp_owner_queue_alias_anchor_a"

    assert queued_b_request.json["previous_response_id"] ==
             "resp_owner_queue_alias_anchor_b"

    assert [anchor_a_log, anchor_b_log, active_log, queued_a_log, queued_b_log] =
             request_logs(setup.pool.id)

    Enum.each([anchor_a_log, anchor_b_log, active_log, queued_a_log, queued_b_log], fn log ->
      assert_native_turn_correlation!(log.correlation_id)
    end)

    assert Enum.all?(
             [anchor_a_log, anchor_b_log, active_log, queued_a_log, queued_b_log],
             &(&1.status == "succeeded")
           )

    assert active_log.request_metadata["codex_session_id"] == origin_session.id
    assert queued_a_log.request_metadata["codex_session_id"] == target_a_session.id
    assert queued_b_log.request_metadata["codex_session_id"] == target_b_session.id
  end

  test "owner-forwarded response processed close while in flight is not pre-request lifecycle" do
    release_ref = make_ref()
    upstream_boundary = chained_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-processed-close"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-processed-close-first", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    try do
      first_payload =
        websocket_payload(setup, "first owner processed close turn", %{
          "request_id" => "ws-owner-processed-close-first"
        })

      assert {:ok, first_state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

      assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
      assert %{"id" => "resp_owner_queue_first"} = Jason.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, processed_state} = owner_socket(auth, "ws-owner-processed-close", turn_state)

    processed_payload =
      Jason.encode!(%{
        "type" => "response.processed",
        "response_id" => "resp_owner_queue_first",
        "request_id" => "ws-owner-processed-close"
      })

    assert {:ok, processed_state} =
             CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, processed_state)

    assert processed_state.request_response_work_started?
    assert_receive {:chained_owner_upstream_processed_blocked, processed_pid, ^release_ref}

    {:ok, reconnect_state} =
      owner_socket(auth, "ws-owner-processed-close-reconnect", turn_state)

    assert reconnect_state.websocket_owner_active_turn_reconnect?
    row_count = length(request_logs(setup.pool.id))

    native_payload =
      websocket_payload(setup, "unknown active descriptor replacement", %{
        "request_id" => "ws-owner-processed-close-native",
        "client_metadata" => %{"turn_id" => "ws-owner-processed-close-native"}
      })

    assert {:push, {:text, native_error}, ^reconnect_state} =
             CodexResponsesSocket.handle_in(
               {native_payload, [opcode: :text]},
               reconnect_state
             )

    assert Jason.decode!(native_error)["error"]["code"] == "owner_busy"

    assert {:push, {:text, processed_error}, ^reconnect_state} =
             CodexResponsesSocket.handle_in(
               {processed_payload, [opcode: :text]},
               reconnect_state
             )

    assert Jason.decode!(processed_error)["error"]["code"] == "owner_busy"
    assert length(request_logs(setup.pool.id)) == row_count
    CodexResponsesSocket.terminate(:closed, reconnect_state)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, processed_state)
        end)

      refute logs =~ WebsocketConnectionLogger.closed_message()
      refute logs =~ WebsocketConnectionLogger.init_failed_message()
      assert_no_websocket_lifecycle_leaks!(logs)

      send(processed_pid, {:chained_owner_upstream_release, release_ref})
      flush_socket_done(processed_state)
    after
      send(processed_pid, {:chained_owner_upstream_release, release_ref})
    end

    assert [first_log | _rest] = request_logs(setup.pool.id)
    assert_native_turn_correlation!(first_log.correlation_id)
    assert first_log.status == "succeeded"
  end

  @tag :replay_active_reattach
  @tag :replay_matrix
  @tag :replay_topology
  test "healthy active owner rejects an exact retry without attachment mutation" do
    release_ref = make_ref()
    upstream_boundary = terminal_blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-active-reconnect"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-active-reconnect-first", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "first owner active reconnect turn", %{
        "request_id" => "ws-owner-active-reconnect-first",
        "client_metadata" => %{
          "turn_id" => "ws-owner-active-reconnect-first",
          "x-codex-turn-metadata" =>
            Jason.encode!(%{
              "turn_id" => "ws-owner-active-reconnect-first",
              "request_kind" => "turn"
            })
        }
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    assert MapSet.size(first_state.tasks) == 1
    [response_task_pid] = MapSet.to_list(first_state.tasks)

    {:ok, second_state} = owner_socket(auth, "ws-owner-active-reconnect-second", turn_state)
    assert second_state.websocket_owner_downstream.epoch == 2
    assert second_state.websocket_owner_active_turn_reconnect? == true

    assert %{active_turn: %{descriptor: %{kind: :native} = active_descriptor}} =
             :sys.get_state(second_state.websocket_owner_pid)

    assert active_descriptor.semantic_turn_key ==
             :crypto.hash(
               :sha256,
               second_state.codex_session.id <> <<0>> <> "ws-owner-active-reconnect-first"
             )

    try do
      assert [in_progress_request] = request_logs(setup.pool.id)
      assert_native_turn_correlation!(in_progress_request.correlation_id)
      assert in_progress_request.status == "in_progress"

      {replay_result, replay_log} =
        with_info_log(fn ->
          CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, second_state)
        end)

      assert {:push, {:text, duplicate_error}, ^second_state} = replay_result
      assert Jason.decode!(duplicate_error)["error"]["code"] == "duplicate_turn"

      assert event_count(replay_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
               1

      assert replay_log =~ "reconnect_disposition=identity_rejected"

      assert second_state.websocket_owner_active_turn_reconnect? == true
      assert MapSet.size(second_state.tasks) == 0
      assert length(request_logs(setup.pool.id)) == 1

      assert length(request_logs(setup.pool.id)) == 1
    after
      {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
      Sandbox.allow(Repo, self(), owner_pid)
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})

      assert {:push, {:text, terminal_frame}, first_state} =
               receive_owner_socket_push(first_state)

      assert Jason.decode!(terminal_frame)["type"] == "response.completed"
      assert {:ok, first_state} = receive_owner_socket_complete(first_state)
      first_state = receive_receiver_delivery_gap_result(response_task_pid, first_state)

      assert {:ok, first_state} =
               acknowledge_response_task_delivery_if_pending(first_state, response_task_pid)

      assert_response_task_stopped!(first_state, response_task_pid)
      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)
      assert :ok = CodexResponsesSocket.terminate(:closed, second_state)
      await_owner_cleanup!(first_state.codex_session.id)
    end
  end

  @tag :replay_protocol_v2
  @tag :replay_topology
  test "router upgrade carries typed RequestOptions through V2 healthy duplicate" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{"id" => "resp_router_v2"}
          })
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    turn_state = "router-v2-typed-options"

    payload =
      websocket_payload(setup, "router typed options", %{
        "request_id" => "router-v2-typed-options",
        "client_metadata" => %{
          "turn_id" => "router-v2-typed-options",
          "x-codex-turn-metadata" =>
            Jason.encode!(%{
              "turn_id" => "router-v2-typed-options",
              "request_kind" => "turn"
            })
        }
      })

    {first_conn, first_ws, first_ref} = public_websocket_connect!(port, setup, turn_state)
    {first_conn, first_ws} = public_websocket_send_text!(first_conn, first_ws, first_ref, payload)
    _ = public_websocket_receive_text!(first_conn, first_ws, first_ref)

    {retry_conn, retry_ws, retry_ref} = public_websocket_connect!(port, setup, turn_state)
    {retry_conn, retry_ws} = public_websocket_send_text!(retry_conn, retry_ws, retry_ref, payload)

    {_retry_conn, _retry_ws, error} =
      public_websocket_receive_text!(retry_conn, retry_ws, retry_ref)

    assert Jason.decode!(error)["error"]["code"] == "duplicate_turn"

    Mint.HTTP.close(first_conn)
    Mint.HTTP.close(retry_conn)

    session =
      Repo.one!(from session in CodexSession, order_by: [desc: session.created_at], limit: 1)

    case WebsocketOwnerSession.lookup(session.id) do
      {:ok, owner_pid} -> GenServer.stop(owner_pid, :normal)
      {:error, :owner_unavailable} -> :ok
    end
  end

  @tag :replay_race
  @tag :replay_topology
  test "active owner reconnect rejects ambiguous frames while prewarm remains local and neutral" do
    for route <- [:direct, :proxy] do
      assert_active_reconnect_frame_matrix(route)
    end
  end

  test "pending replacement prewarm stays local and preserves the handoff in both topologies" do
    for route <- [:direct, :proxy] do
      assert_pending_replacement_prewarm_neutral(route)
    end
  end

  test "cancelled owner reconnect admits one edited replacement only after fenced readiness" do
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-edited-replacement"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-edited-replacement-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "edited replacement predecessor", %{
        "request_id" => "ws-owner-edited-replacement-a",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, first_worker_pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    owner_upstream_pid = :sys.get_state(owner_pid).upstream_pid

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    assert %{
             active_turn: %{
               descriptor: %{kind: :native},
               canceled_result: _canceled_result
             }
           } = :sys.get_state(owner_pid)

    {:ok, replacement_state} =
      owner_socket(auth, "ws-owner-edited-replacement-b", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    cancelled_equal_payload =
      websocket_payload(setup, "cancelled equal predecessor replay", %{
        "request_id" => "ws-owner-edited-replacement-a",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-a"}
      })

    {cancelled_equal_result, cancelled_equal_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in(
          {cancelled_equal_payload, [opcode: :text]},
          replacement_state
        )
      end)

    assert {:push, {:text, cancelled_equal_error}, ^replacement_state} =
             cancelled_equal_result

    assert Jason.decode!(cancelled_equal_error)["error"]["code"] == "owner_busy"

    assert event_count(
             cancelled_equal_log,
             WebsocketConnectionLogger.reconnect_disposition_message()
           ) == 1

    assert cancelled_equal_log =~ "reconnect_disposition=owner_busy"
    assert length(request_logs(setup.pool.id)) == 1

    replacement_payload =
      websocket_payload(setup, "edited replacement successor", %{
        "request_id" => "ws-owner-edited-replacement-b",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-b"}
      })

    assert {:ok, pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               replacement_state
             )

    assert is_map(pending_state.websocket_owner_pending_handoff)
    assert MapSet.size(pending_state.tasks) == 0
    assert length(request_logs(setup.pool.id)) == 1

    assert {:ok, ^pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               pending_state
             )

    third_payload =
      websocket_payload(setup, "third pending replacement", %{
        "request_id" => "ws-owner-edited-replacement-d",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-d"}
      })

    {third_result, third_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in(
          {third_payload, [opcode: :text]},
          pending_state
        )
      end)

    assert {:push, {:text, third_error}, ^pending_state} = third_result

    assert Jason.decode!(third_error)["error"]["code"] == "owner_busy"
    assert event_count(third_log, WebsocketConnectionLogger.reconnect_disposition_message()) == 1
    assert third_log =~ "reconnect_disposition=owner_busy"
    assert length(request_logs(setup.pool.id)) == 1

    assert_receive {:websocket_owner_handoff_ready, _, _, _, _, _} = ready,
                   @handoff_detection_timeout_ms

    assert {:ok, admitted_state} = CodexResponsesSocket.handle_info(ready, pending_state)
    assert admitted_state.websocket_owner_pending_handoff == nil
    assert MapSet.size(admitted_state.tasks) == 1

    assert_receive {:controller_handoff_replacement_started, 2},
                   @handoff_detection_timeout_ms

    assert length(request_logs(setup.pool.id)) == 2

    assert {:ok, admitted_state} = receive_owner_socket_complete(admitted_state)
    assert {:ok, admitted_state} = receive_socket_done(admitted_state)

    assert [predecessor, replacement] = request_logs(setup.pool.id)
    assert predecessor.last_error_code == "client_disconnected"
    assert replacement.status == "succeeded"
    assert predecessor.correlation_id != replacement.correlation_id

    following_payload =
      websocket_payload(setup, "following replacement turn", %{
        "request_id" => "ws-owner-edited-replacement-c",
        "client_metadata" => %{"turn_id" => "ws-owner-edited-replacement-c"}
      })

    assert {:ok, following_state} =
             CodexResponsesSocket.handle_in(
               {following_payload, [opcode: :text]},
               admitted_state
             )

    assert_receive {:controller_handoff_replacement_started, 3},
                   @handoff_detection_timeout_ms

    assert {:ok, following_state} = receive_owner_socket_complete(following_state)
    assert {:ok, following_state} = receive_socket_done(following_state)

    assert [_predecessor, _replacement, following] = request_logs(setup.pool.id)
    assert following.status == "succeeded"

    assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    assert :sys.get_state(owner_pid).upstream_pid == owner_upstream_pid
    refute inspect(request_logs(setup.pool.id)) =~ "previous_response_generation_mismatch"

    assert Repo.aggregate(
             from(attempt in Attempt,
               join: request in Request,
               on: request.id == attempt.request_id,
               where: request.pool_id == ^setup.pool.id
             ),
             :count
           ) ==
             3

    assert Repo.aggregate(
             from(turn in CodexTurn,
               where: turn.codex_session_id == ^first_state.codex_session.id
             ),
             :count
           ) == 3

    refute Process.alive?(first_worker_pid)
    CodexResponsesSocket.terminate(:closed, first_state)
    CodexResponsesSocket.terminate(:closed, following_state)
  end

  test "pending edited replacement socket close cancels once without replacement rows or leaks" do
    private_sentinel = "REPLAY_PRIVATE_PENDING_CLOSE_SENTINEL"
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-pending-close"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-pending-close-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "pending close predecessor", %{
        "request_id" => "ws-owner-pending-close-a",
        "client_metadata" => %{"turn_id" => "ws-owner-pending-close-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, predecessor_pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    parent = self()

    socket_pid =
      spawn(fn ->
        receive do
          :start ->
            {:ok, state} =
              owner_socket(auth, "ws-owner-pending-close-b", turn_state,
                websocket_owner_forwarder_opts: [upstream: upstream_boundary]
              )

            receive do
              {:frame, payload} ->
                {:ok, pending_state} =
                  CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

                pending = pending_state.websocket_owner_pending_handoff
                capability_pid = pending.prepared.provenance.capability.server
                send(parent, {:pending_close_socket_ready, self(), capability_pid})

                receive do
                  :terminate ->
                    :ok = CodexResponsesSocket.terminate(:closed, pending_state)
                end
            end
        end
      end)

    Sandbox.allow(Repo, self(), socket_pid)
    socket_monitor = Process.monitor(socket_pid)
    send(socket_pid, :start)

    replacement_payload =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "ws-owner-pending-close-b",
        "client_metadata" => %{"turn_id" => "ws-owner-pending-close-b"}
      })

    classification_log =
      capture_info_log(fn ->
        send(socket_pid, {:frame, replacement_payload})

        assert_receive {:pending_close_socket_ready, ^socket_pid, capability_pid},
                       @handoff_detection_timeout_ms

        Process.put(:pending_close_capability_pid, capability_pid)
      end)

    capability_pid = Process.delete(:pending_close_capability_pid)
    capability_monitor = Process.monitor(capability_pid)
    owner_pending = :sys.get_state(owner_pid).pending_handoff

    assert length(request_logs(setup.pool.id)) == 1

    assert event_count(
             classification_log,
             WebsocketConnectionLogger.reconnect_disposition_message()
           ) == 1

    assert classification_log =~ "reconnect_disposition=replacement_handoff"
    refute classification_log =~ private_sentinel

    close_log =
      capture_info_log(fn ->
        send(socket_pid, :terminate)

        assert_receive {:DOWN, ^socket_monitor, :process, ^socket_pid, :normal},
                       @handoff_detection_timeout_ms
      end)

    assert_receive {:DOWN, ^capability_monitor, :process, ^capability_pid, :normal},
                   @handoff_detection_timeout_ms

    assert event_count(close_log, WebsocketConnectionLogger.handoff_outcome_message()) == 1
    assert close_log =~ "handoff_outcome=socket_closed"
    refute close_log =~ private_sentinel
    assert %{pending_handoff: nil} = :sys.get_state(owner_pid)

    send(
      owner_pid,
      {:websocket_owner_handoff_soft_timeout, owner_pending.control_ref, owner_pending.soft_token}
    )

    send(
      owner_pid,
      {:websocket_owner_handoff_absolute_timeout, owner_pending.control_ref,
       owner_pending.absolute_token}
    )

    send(
      socket_pid,
      {:websocket_owner_handoff_ready, "stale", 99, self(), socket_pid, make_ref()}
    )

    assert %{pending_handoff: nil} = :sys.get_state(owner_pid)

    assert [predecessor] = request_logs(setup.pool.id)

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id == ^predecessor.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(turn in CodexTurn, where: turn.request_id == ^predecessor.id),
             :count
           ) == 1

    assert Enum.all?(
             Repo.all(from(entry in LedgerEntry, where: entry.pool_id == ^setup.pool.id)),
             fn entry ->
               entry.request_id == predecessor.id
             end
           )

    refute Process.alive?(predecessor_pid)
    CodexResponsesSocket.terminate(:closed, first_state)
  end

  test "stuck edited replacement times out once without replacement rows" do
    private_sentinel = "REPLAY_PRIVATE_TIMEOUT_SENTINEL"
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-handoff-timeout"

    {:ok, first_state} =
      owner_socket(auth, "ws-owner-handoff-timeout-a", turn_state,
        websocket_owner_forwarder_opts: [
          upstream: upstream_boundary,
          handoff_soft_timeout_ms: 25,
          handoff_absolute_timeout_ms: 100
        ]
      )

    first_payload =
      websocket_payload(setup, "timeout predecessor", %{
        "request_id" => "ws-owner-handoff-timeout-a",
        "client_metadata" => %{"turn_id" => "ws-owner-handoff-timeout-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, _predecessor_pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    {:ok, replacement_state} =
      owner_socket(auth, "ws-owner-handoff-timeout-b", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    replacement_payload =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "ws-owner-handoff-timeout-b",
        "client_metadata" => %{"turn_id" => "ws-owner-handoff-timeout-b"}
      })

    owner_monitor = Process.monitor(owner_pid)
    assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    assert Process.alive?(owner_pid)

    assert {:ok, pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               replacement_state
             )

    owner_pending = :sys.get_state(owner_pid).pending_handoff

    send(
      owner_pid,
      {:websocket_owner_handoff_soft_timeout, owner_pending.control_ref, owner_pending.soft_token}
    )

    assert length(request_logs(setup.pool.id)) == 1
    assert_receive {:websocket_owner_handoff_ready, _, _, _, _, _}, @handoff_detection_timeout_ms

    owner_pending = :sys.get_state(owner_pid).pending_handoff

    send(
      owner_pid,
      {:websocket_owner_handoff_absolute_timeout, owner_pending.control_ref,
       owner_pending.absolute_token}
    )

    {timeout_result, timeout_log} =
      with_info_log(fn ->
        assert_receive {:websocket_owner_handoff_failed, _, _, _, _, _, :owner_forward_timeout} =
                         failed,
                       @handoff_detection_timeout_ms

        CodexResponsesSocket.handle_info(failed, pending_state)
      end)

    assert {:push, {:text, timeout_error}, timeout_state} = timeout_result
    assert Jason.decode!(timeout_error)["error"]["code"] == "owner_forward_timeout"
    assert timeout_state.websocket_owner_pending_handoff == nil
    assert event_count(timeout_log, WebsocketConnectionLogger.handoff_outcome_message()) == 1
    assert timeout_log =~ "handoff_outcome=timeout"
    refute timeout_log =~ private_sentinel
    assert length(request_logs(setup.pool.id)) == 1

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :normal},
                   @handoff_detection_timeout_ms

    assert {:error, :owner_unavailable} =
             WebsocketOwnerSession.lookup(timeout_state.codex_session.id)
  end

  test "owner forwarding does not acquire a second proxy websocket admission slot" do
    with_single_proxy_websocket_slot(fn ->
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_admission"}))
      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      {:ok, state} =
        CodexResponsesSocket.init(%{
          auth: auth,
          opts: %{
            request_id: "ws-owner-admission",
            accepted_turn_state: "stable-ws-owner-admission",
            client_ip: "127.0.0.1"
          }
        })

      try do
        payload = websocket_payload(setup, "single admission owner turn")

        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
        assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
        assert %{"id" => "resp_owner_admission"} = Jason.decode!(frame)
        assert {:ok, _state} = receive_socket_done(state)

        assert [_request] = FakeUpstream.requests(upstream)
        assert [request_log] = request_logs(setup.pool.id)
        assert request_log.status == "succeeded"
        assert request_log.transport == "websocket"
      after
        CodexResponsesSocket.terminate(:closed, state)
      end
    end)
  end

  test "owner-forwarded websocket overloads keep internal causes off the Codex wire" do
    for {internal_reason, queue_limit, queue_timeout_ms} <- [
          {"bulkhead_rejected", 0, 1_000},
          {"bulkhead_queue_timeout", 1, 25}
        ] do
      with_proxy_websocket_bulkhead(queue_limit, queue_timeout_ms, fn ->
        upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
        setup = gateway_setup(upstream)
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

        {:ok, state} =
          owner_socket(
            auth,
            "ws-owner-overload-#{internal_reason}",
            "owner-overload-#{internal_reason}"
          )

        assert {:ok, lease} =
                 Admission.acquire("proxy_websocket", %{request_id: "held-#{internal_reason}"})

        try do
          payload = websocket_payload(setup, "synthetic owner overload")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)

          assert %{
                   "type" => "error",
                   "status" => 503,
                   "error" => %{
                     "code" => "server_is_overloaded",
                     "message" => "gateway route class is temporarily overloaded",
                     "param" => nil,
                     "type" => "server_error"
                   }
                 } = Jason.decode!(error_frame)

          refute error_frame =~ internal_reason
          assert FakeUpstream.requests(upstream) == []
          assert Repo.aggregate(Request, :count) == 0
          assert Repo.aggregate(Attempt, :count) == 0
          assert Repo.aggregate(LedgerEntry, :count) == 0
        after
          Admission.release(lease)
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)
    end
  end

  test "owner-forwarded websocket terminal usage settles priced gpt-5.5 request logs" do
    terminal_usage = %{
      "input_tokens" => 123,
      "input_tokens_details" => %{"cached_tokens" => 17},
      "output_tokens" => 45,
      "reasoning_tokens" => 6,
      "total_tokens" => 168
    }

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_priced_gpt55",
          "object" => "response",
          "usage" => terminal_usage
        })
      )

    setup = gateway_setup(upstream)

    model =
      setup.model
      |> Ecto.Changeset.change(%{
        exposed_model_id: "gpt-5.5",
        upstream_model_id: "gpt-5.5",
        pricing_ref: "gpt-5.5",
        metadata:
          put_in(
            setup.model.metadata,
            ["source_assignment_models", setup.assignment.id, "slug"],
            "gpt-5.5"
          )
      })
      |> Repo.update!()

    pricing_snapshot!(model, %{
      input_token_micros: Decimal.new(10),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(20),
      reasoning_token_micros: Decimal.new(30)
    })

    setup = %{setup | model: model}
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-priced-gpt55", "owner-priced-gpt55")

    try do
      payload = websocket_payload(setup, "owner priced usage")

      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert %{"id" => "resp_owner_priced_gpt55"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end

    assert [request] = request_logs(setup.pool.id)
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert request.requested_model == "gpt-5.5"

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 123
    assert settlement.cached_input_tokens == 17
    assert settlement.output_tokens == 45
    assert settlement.reasoning_tokens == 6
    assert settlement.total_tokens == 168
    assert settlement.pricing_snapshot_id
    assert Decimal.positive?(settlement.settled_cost_micros)
    assert settlement.details["pricing_status"] == "priced"
    assert is_binary(settlement.details["settled_cost_micros"])

    assert %{items: [log], total: 1} =
             Accounting.list_request_logs(setup.pool, filters: %{request_id: request.id})

    assert log.usage_status == "usage_known"
    assert log.token_counts.total_tokens == 168
    assert log.cost.status == "priced"
    assert %Decimal{} = log.cost.usd
    assert Decimal.positive?(log.cost.usd)
  end

  test "owner-forwarded response.processed reports owner unavailable when the local owner is gone" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-unavailable",
          accepted_turn_state: "stable-ws-owner-unavailable",
          client_ip: "127.0.0.1"
        }
      })

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    GenServer.stop(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_unavailable"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)

      assert %{
               "type" => "error",
               "error" => %{"code" => "upstream_websocket_forward_failed", "message" => message}
             } = Jason.decode!(error_frame)

      assert message =~ "owner_unavailable"
      refute error_frame =~ "pinned_continuation_reauth_required"
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner transport session mismatch rejects response.create before upstream submit" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-guard-create", "owner-guard-create")
    {:ok, other_state} = owner_socket(auth, "ws-owner-guard-create-other", "owner-guard-other")

    stale_state = %{state | codex_session: other_state.codex_session}

    try do
      payload = websocket_payload(setup, "owner transport guard create")

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{
               "status" => 409,
               "error" => %{
                 "code" => "stale_owner",
                 "message" => "websocket owner lease is stale"
               }
             } = Jason.decode!(error_frame)

      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "failed"
      assert request.response_status_code == 409
      assert request.last_error_code == "stale_owner"

      assert [attempt] = Repo.all(from a in Attempt, where: a.request_id == ^request.id)
      assert attempt.status == "failed"
      assert attempt.network_error_code == "stale_owner"
    after
      CodexResponsesSocket.terminate(:closed, state)
      CodexResponsesSocket.terminate(:closed, other_state)
    end
  end

  test "owner transport session mismatch rejects response.processed without local fallback" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-guard-processed", "owner-guard-processed")
    {:ok, other_state} = owner_socket(auth, "ws-owner-guard-processed-other", "owner-guard-other")

    stale_state = %{state | codex_session: other_state.codex_session}

    try do
      processed_payload =
        Jason.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_guard_processed"
        })

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{
               "status" => 502,
               "error" => %{"code" => "upstream_websocket_forward_failed", "message" => message}
             } = Jason.decode!(error_frame)

      assert message =~ "stale_owner"
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0
      assert [] = request_logs(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
      CodexResponsesSocket.terminate(:closed, other_state)
    end
  end

  test "owner-forwarded anomalous close before request reservation logs bounded lifecycle metadata only" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-pre-request-close-#{System.unique_integer([:positive])}"
    turn_state = "stable-owner-pre-request-close-#{System.unique_integer([:positive])}"

    logs =
      capture_websocket_lifecycle_log(fn ->
        assert {:ok, state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts:
                     owner_lifecycle_request_options(request_id, turn_state,
                       authorization_header: "Bearer owner-close-secret-sentinel",
                       idempotency_key: "owner-close-idempotency-secret",
                       forwarded_headers: [{"cookie", "owner-close-cookie-secret"}]
                     ),
                   raw_frame: @sentinel
                 })

        refute state.request_response_work_started?
        assert is_map(state.websocket_owner_downstream)
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        WebsocketConnectionLogger.closed_message(),
        ~w(codex_session_id downstream_epoch elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(owner_instance_id proxy_instance_id)
      )

    owner_instance_id = String.replace(Atom.to_string(node()), ~r/[^a-zA-Z0-9_.:-]+/, "_")

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=_backend-api_codex_responses"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "phase=terminate"
    assert line =~ "reason_class=closed"
    assert line =~ "codex_session_id="
    assert line =~ "downstream_epoch=1"
    assert line =~ "owner_instance_id=#{owner_instance_id}"
    refute logs =~ "websocket owner detach failed"
    refute logs =~ "owner_unavailable"
    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner-forwarded cleanup-only remote detach failure stays quiet without active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-cleanup-only-detach"
    turn_state = "stable-ws-owner-cleanup-only-detach"

    assert {:ok, state} =
             CodexResponsesSocket.init(%{
               auth: auth,
               opts: owner_lifecycle_request_options(request_id, turn_state)
             })

    remote_node = :"codex_pooler@nodedown-cleanup-only-detach.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          RequestOptions.put_transport(state.opts,
            websocket_owner_forwarder_opts:
              WebsocketOwnerNodeHarness.node_client_opts([remote_node],
                calls: %{remote_node => :nodedown}
              )
          )
    }

    try do
      logs =
        capture_log([level: :warning], fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, remote_state)
        end)

      assert logs == ""
      assert_no_leak!("cleanup-only remote detach logs", logs)
      assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  @tag :owner_detach_failure_recovery
  test "owner detach unavailable during socket terminate is observable and interrupts active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_detach"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-detach-unavailable",
          accepted_turn_state: "stable-ws-owner-detach-unavailable",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    suspend_cleanup_task!(state)
    owner = state.websocket_owner_pid
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, @handoff_detection_timeout_ms
    remote_node = :"codex_pooler@nodedown-detach.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :nodedown}
            )
          )
    }

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      assert logs =~ "websocket owner detach failed"
      assert logs =~ "owner_unavailable"
      assert_no_leak!("owner detach failure logs", logs)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "owner_unavailable"
      })

      reloaded_session = Repo.get!(CodexSession, state.codex_session.id)
      assert reloaded_session.owner_lease_expires_at

      assert DateTime.diff(
               reloaded_session.owner_lease_expires_at,
               reloaded_session.disconnected_at,
               :second
             ) == 300
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner detach unavailable during socket terminate with typed request options is observable and interrupts active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_detach_typed"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-detach-unavailable-typed",
          accepted_turn_state: "stable-ws-owner-detach-unavailable-typed",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    remote_node = :"codex_pooler@nodedown-detach-typed.example"

    typed_opts =
      RequestOptions.for_websocket(%{})
      |> RequestOptions.put_continuity(
        accepted_turn_state: "stable-ws-owner-detach-unavailable-typed",
        previous_response_id: nil,
        response_id: nil,
        session_header: nil,
        session_key: nil,
        conversation_key: nil,
        owner_instance_id: nil,
        bridge_owner_lease_ttl_seconds: nil,
        reconnect_window_seconds: nil,
        codex_session: nil,
        codex_turn_id: nil,
        authenticated_owner_attach: false
      )
      |> RequestOptions.put_runtime_context(
        now: nil,
        interrupt_reason: nil,
        gateway_debug_payload: nil
      )
      |> RequestOptions.put_transport(
        websocket_owner_forwarder_opts:
          WebsocketOwnerNodeHarness.node_client_opts([remote_node],
            calls: %{remote_node => :nodedown}
          )
      )

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts: typed_opts
    }

    try do
      assert %RequestOptions{} = remote_state.opts
      assert is_nil(remote_state.opts.continuity.previous_response_id)
      assert is_nil(remote_state.opts.runtime.interrupt_reason)

      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      assert logs =~ "websocket owner detach failed"
      assert logs =~ "owner_unavailable"
      refute logs =~ "Protocol.UndefinedError"
      assert_no_leak!("typed owner detach failure logs", logs)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "owner_unavailable"
      })
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  @tag :rollout_drain_deadline_contract
  test "local owner deadline expiry releases lease interrupts active turn and permits fresh owner reconnect" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_death"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-clean-exit", "stable-ws-owner-clean-exit",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "deadline expiry while owner turn is active")
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    assert [turn] =
             Repo.all(
               from turn in CodexTurn,
                 where: turn.codex_session_id == ^state.codex_session.id
             )

    request = Repo.get!(Request, turn.request_id)
    attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^request.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    old_token = state.codex_session.owner_lease_token
    owner_ref = Process.monitor(owner_pid)

    harness = start_rollout_drain_harness()
    deadline = harness.deadline

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 25, deadline_margin_ms: 20, deadline_floor_ms: 10] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, 10}
    assert Repo.get!(CodexTurn, turn.id).status == "in_progress"
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(harness.deadline, 10)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}
    assert_response_task_stopped!(state)
    assert %{turns_completed: 0, turns_aborted: 1} = Task.await(drain_task, 1_000)

    assert released_lease = released_owner_lease(state.codex_session.id, old_token)
    assert released_lease.metadata["release_reason"] == "owner_drained"
    refute released_lease.metadata["release_reason"] == "pinned_continuation_reauth_required"
    refute released_lease.metadata["release_reason"] == "owner_crashed"
    assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, turn.id).error_code == "owner_drained"
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == attempt.id
    assert Repo.get!(Request, request.id).status == "failed"
    assert Repo.get!(Request, request.id).response_status_code == 499
    assert Repo.get!(Request, request.id).last_error_code == "owner_drained"
    refute Repo.get!(Request, request.id).last_error_code == "pinned_continuation_reauth_required"
    assert Repo.get!(Attempt, attempt.id).network_error_code == "owner_drained"

    {:ok, reconnect_state} =
      owner_socket(
        auth,
        "ws-owner-clean-exit-reconnect",
        "stable-ws-owner-clean-exit"
      )

    try do
      assert reconnect_state.codex_session.id == state.codex_session.id
      assert reconnect_state.codex_session.owner_lease_token != old_token
      assert {:ok, fresh_owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      assert fresh_owner_pid != owner_pid

      assert active_owner_lease(reconnect_state.codex_session.id).lease_token ==
               reconnect_state.codex_session.owner_lease_token
    after
      CodexResponsesSocket.terminate(:closed, reconnect_state)
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  test "local owner crash interrupts active turn without waiting for lease expiry" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_crash"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-crash",
          accepted_turn_state: "stable-ws-owner-crash",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    release_task = suspend_cleanup_task!(state)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}

    owner_monitor = state.websocket_owner_monitor
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :killed} = owner_down

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, state) end)

    assert {:stop, :normal, {1011, "websocket owner crashed"}, stopped_state} =
             handle_result

    refute Map.has_key?(stopped_state, :websocket_owner_monitor)
    refute Map.has_key?(stopped_state, :websocket_owner_pid)
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "pinned_continuation_reauth_required"
    refute logs =~ "owner_drained"
    refute logs =~ "client_disconnected"
    assert_no_leak!("local owner crash monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_crashed"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_crashed"

    release_task.()

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(stopped_state, :websocket_owner_downstream)
    )
  end

  test "unexpected owner monitor exit still crashes active turn" do
    assert_abnormal_owner_monitor_down_crashes_active_turn!(
      {:unexpected_owner_exit, :boom},
      "unexpected-exit"
    )
  end

  test "owner monitor normal exit drains active turn without closing websocket" do
    assert_graceful_owner_monitor_down_drains_active_turn!(:normal, "normal")
  end

  test "owner monitor shutdown exit drains active turn and finalizes request attempt turn" do
    assert_graceful_owner_monitor_down_drains_active_turn!(:shutdown, "shutdown")
  end

  test "owner monitor rolling restart exit drains active turn and releases lease" do
    assert_graceful_owner_monitor_down_drains_active_turn!(
      {:shutdown, :rolling_restart},
      "rolling-restart"
    )
  end

  test "idle owner monitor shutdown exit drains lease without warning or finalization" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_idle_owner_shutdown"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-idle-shutdown",
          accepted_turn_state: "stable-ws-owner-monitor-idle-shutdown",
          client_ip: "127.0.0.1"
        }
      })

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(:shutdown)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, warning_logs} =
      with_log([level: :warning], fn ->
        CodexResponsesSocket.handle_info(owner_down, monitored_state)
      end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    assert warning_logs == ""
    assert_no_leak!("idle owner shutdown monitor logs", warning_logs)

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    assert Repo.aggregate(
             from(r in Request, where: r.pool_id == ^setup.pool.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(a in Attempt,
               join: r in Request,
               on: a.request_id == r.id,
               where: r.pool_id == ^setup.pool.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id),
             :count
           ) == 0

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  test "intentional stale owner replacement does not close monitored socket as crashed" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_down"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-down",
          accepted_turn_state: "stable-ws-owner-stale-down",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    release_task = suspend_cleanup_task!(state)
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)
    owner_monitor = state.websocket_owner_monitor

    :ok = GenServer.stop(owner_pid, {:shutdown, :stale_owner})
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, {:shutdown, :stale_owner}}

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, {:shutdown, :stale_owner}} =
                     owner_down

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, state) end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    refute logs =~ "owner_crashed"
    refute logs =~ "owner_drained"
    refute logs =~ "pinned_continuation_reauth_required"
    assert_no_leak!("stale owner monitor logs", logs)

    assert Repo.get!(Request, request.id).status == "in_progress"
    assert Repo.get!(Attempt, attempt.id).status == "in_progress"
    assert Repo.get!(CodexTurn, turn.id).status == "in_progress"

    refute released_owner_lease_optional(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           )

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.codex_session.owner_lease_token

    assert kept_state.codex_session.owner_lease_token == state.codex_session.owner_lease_token

    release_task.()

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  @tag :replay_topology
  test "stale owner token rejects before upstream send" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-token",
          accepted_turn_state: "stable-ws-owner-stale-token",
          client_ip: "127.0.0.1"
        }
      })

    stale_state = state
    takeover_token = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    state.codex_session
    |> Ecto.Changeset.change(%{owner_lease_token: takeover_token, updated_at: now})
    |> Repo.update!()

    active_owner_lease(state.codex_session.id)
    |> Ecto.Changeset.change(%{lease_token: takeover_token, renewed_at: now, updated_at: now})
    |> Repo.update!()

    try do
      payload = websocket_payload(setup, "stale token should not reach upstream")

      assert {:ok, stale_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, stale_state)

      assert {:push, {:text, error_frame}, _state} = receive_socket_done(stale_state)

      assert %{"error" => %{"code" => "stale_owner", "message" => message}} =
               Jason.decode!(error_frame)

      assert message == "websocket owner lease is stale"
      assert FakeUpstream.count(upstream) == 0
    after
      CodexResponsesSocket.terminate(
        :closed,
        Map.delete(stale_state, :websocket_owner_downstream)
      )
    end

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    logs =
      capture_info_log(fn ->
        assert :ok = GenServer.stop(owner_pid, {:shutdown, :stale_owner})
        assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, {:shutdown, :stale_owner}}
      end)

    refute logs =~ "websocket owner exit persistence failed"
    assert logs =~ "owner_exit_reason=stale_owner"
    assert active_owner_lease(state.codex_session.id).lease_token == takeover_token
    assert_no_leak!("stale owner cleanup logs", logs)
  end

  @tag :owner_drained_terminal_state
  @tag :replay_cleanup
  test "owner drain sends safe interruption releases lease and suppresses later stale downstream terminate" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_drain"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-drain-first",
          accepted_turn_state: "stable-ws-owner-drain",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: first_state} =
      active_socket_turn_fixture(setup, upstream, first_state)

    release_task = suspend_cleanup_task!(first_state)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    assert :ok = WebsocketOwnerSession.drain_owner(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    assert_receive {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.metadata.reason == "owner_drained"

    assert released_owner_lease(
             first_state.codex_session.id,
             first_state.codex_session.owner_lease_token
           )

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: first_state.codex_session,
      error_code: "owner_drained"
    })

    release_task.()

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-drain-second",
          accepted_turn_state: "stable-ws-owner-drain",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert second_state.websocket_owner_downstream.epoch == 1
      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(second_state.codex_session.id)
      assert Repo.get!(CodexTurn, turn.id).status == "interrupted"
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  @tag :owner_drained_terminal_state
  test "late owner drain preserves already succeeded request attempt and turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_late_drain"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-late-drain",
          accepted_turn_state: "stable-ws-owner-late-drain",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "owner_late_drain_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    owner_ref = Process.monitor(owner_pid)

    assert :ok = WebsocketOwnerSession.drain_owner(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    assert_receive {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id,
                    {:error, :owner_drained, safe_payload}}

    assert safe_payload.metadata.reason == "owner_drained"

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    assert Repo.get!(CodexSession, state.codex_session.id).status == state.codex_session.status

    logs = capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, state) end)

    refute logs =~ "websocket owner detach failed"
    refute logs =~ "owner_unavailable"
    assert_no_leak!("late owner drain detach logs", logs)

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
  end

  @tag :rollout_drain_t5
  test "T5 socket terminate aborts an active owner while rollout drain waits" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-rollout-wait-disconnect", "rollout-wait-disconnect",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "disconnect while rollout drain waits")
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    owner_pid = state.websocket_owner_pid
    owner_ref = Process.monitor(owner_pid)

    session =
      Repo.get_by!(CodexSession, session_key: turn_state_session_key("rollout-wait-disconnect"))

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    request = Repo.get!(Request, turn.request_id)
    attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

    previous_drain_config = Application.get_env(:codex_pooler, RolloutDrain)
    harness = start_rollout_drain_harness()
    deadline = harness.deadline
    WebsocketRolloutDrainSupport.configure_rollout_drain_server(harness.name)

    on_exit(fn ->
      if previous_drain_config do
        Application.put_env(:codex_pooler, RolloutDrain, previous_drain_config)
      else
        Application.delete_env(:codex_pooler, RolloutDrain)
      end
    end)

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    try do
      assert_receive {:rollout_drain_deadline_wait, ^deadline, _wait_ms}
      assert Process.alive?(owner_pid)

      terminate_task =
        Task.async(fn -> CodexResponsesSocket.terminate({:shutdown, :rollout}, state) end)

      assert :ok = Task.await(terminate_task, 1_000)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}
      assert_response_task_stopped!(state)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: session,
        error_code: "owner_drained"
      })

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert %{
               owners_seen: 1,
               owners_drained: 0,
               owners_failed: 1,
               turns_completed: 0,
               turns_aborted: 0
             } = Task.await(drain_task, 1_000)

      refute_received {:rollout_drain_deadline_wait, ^deadline, _wait_ms}
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  @tag :rollout_drain_t1
  @tag :rollout_drain_t7
  test "T1/T7 real terminal succeeds before owner stop and precedes the reconnect close" do
    release_ref = make_ref()

    terminal = %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_rollout_terminal_order", "status" => "completed"}
    }

    upstream =
      start_upstream(
        FakeUpstream.websocket_terminal_then_close_barrier(terminal,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = "ws-owner-rollout-terminal-order"
    turn_state = "stable-ws-owner-rollout-terminal-order"
    {:ok, state} = owner_socket(auth, request_id, turn_state)
    owner_pid = state.websocket_owner_pid
    owner_ref = Process.monitor(owner_pid)

    payload = websocket_payload(setup, "synthetic rollout terminal ordering")
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid,
                    ^release_ref},
                   1_000

    harness = start_rollout_drain_harness()
    deadline = harness.deadline

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 500] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, wait_ms}
    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

    assert {:push, {:text, terminal_frame}, state} = receive_owner_socket_push(state)
    assert %{"type" => "response.completed"} = Jason.decode!(terminal_frame)
    assert {:ok, state} = receive_owner_socket_complete(state)
    assert {:ok, state} = receive_socket_done(state)

    turn =
      Repo.one!(
        from turn in CodexTurn,
          where: turn.codex_session_id == ^state.codex_session.id
      )

    request = Repo.get!(Request, turn.request_id)
    attempt = Repo.one!(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

    reconnect_logs =
      capture_log([level: :warning], fn ->
        assert {:stop, :normal, {1001, "websocket owner is draining"}, _reconnect_state} =
                 owner_socket(auth, "ws-owner-rollout-terminal-order-reconnect", turn_state)
      end)

    assert reconnect_logs =~ WebsocketConnectionLogger.init_failed_message()
    assert reconnect_logs =~ "phase=init"
    assert reconnect_logs =~ "reason_class=owner_drained"
    refute reconnect_logs =~ turn_state
    refute reconnect_logs =~ "resp_rollout_terminal_order"
    refute reconnect_logs =~ @sentinel
    refute reconnect_logs =~ "authorization"
    refute reconnect_logs =~ "bearer"

    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, wait_ms)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}
    assert %{turns_completed: 1, turns_aborted: 0} = Task.await(drain_task, 1_000)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, close_barrier_pid,
                    ^release_ref},
                   1_000

    send(close_barrier_pid, {:fake_upstream_release_websocket, release_ref})
    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

    CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
  end

  @tag :rollout_drain_t8
  test "T8 delayed old-owner termination preserves replacement ownership and turn state" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, old_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-delayed-terminate",
        owner_instance_id: "old-owner.example"
      })

    old_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    {:ok, old_owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: old_session.id,
        owner_lease_token: old_session.owner_lease_token,
        owner_instance_id: old_session.owner_instance_id,
        upstream: old_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _old_upstream_pid}

    on_exit(fn ->
      if Process.alive?(old_owner), do: GenServer.stop(old_owner)
    end)

    old_owner_ref = Process.monitor(old_owner)
    old_lease = active_owner_lease(old_session.id)

    replacement_owner_instance = "replacement-owner.example"

    replacement_opts =
      %{owner_instance_id: replacement_owner_instance}
      |> RequestOptions.for_websocket()

    assert {:ok, replacement_session} =
             SessionContinuity.replace_unavailable_owner_lease(old_session, replacement_opts)

    replacement_lease = active_owner_lease(old_session.id)
    assert replacement_lease.lease_token == replacement_session.owner_lease_token
    assert replacement_lease.lease_token != old_lease.lease_token
    assert replacement_lease.owner_instance_id == replacement_owner_instance

    replacement_upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())

    {:ok, replacement_owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: replacement_session.id,
        owner_lease_token: replacement_session.owner_lease_token,
        owner_instance_id: replacement_session.owner_instance_id,
        upstream: replacement_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _replacement_upstream_pid}

    on_exit(fn ->
      if Process.alive?(replacement_owner), do: GenServer.stop(replacement_owner)
    end)

    %{request: request, attempt: attempt, turn: turn} =
      active_turn_fixture(setup, auth, replacement_session)

    assert :ok = GenServer.stop(old_owner)
    assert_receive {:DOWN, ^old_owner_ref, :process, ^old_owner, :normal}

    assert Process.alive?(replacement_owner)
    replacement_request = Repo.get!(Request, request.id)
    replacement_attempt = Repo.get!(Attempt, attempt.id)
    replacement_turn = Repo.get!(CodexTurn, turn.id)
    replacement_session = Repo.get!(CodexSession, replacement_session.id)

    assert replacement_request.status == "in_progress"
    assert is_nil(replacement_request.last_error_code)
    assert replacement_attempt.status == "in_progress"
    assert is_nil(replacement_attempt.network_error_code)
    assert replacement_turn.status == "in_progress"
    assert replacement_turn.request_id == replacement_request.id
    assert replacement_turn.codex_session_id == replacement_session.id
    assert is_nil(replacement_turn.error_code)
    assert replacement_session.status == "active"

    assert replacement_session.owner_lease_token == replacement_lease.lease_token

    assert Repo.get!(BridgeOwnerLease, replacement_lease.id).status == "active"
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "replacement_owner_turn"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
    assert :ok = GenServer.stop(replacement_owner)
    assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
  end

  @tag :rollout_drain_t8
  test "T8 current-owner termination releases its lease and interrupts its active turn" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-current-owner-terminate",
        owner_instance_id: "current-owner.example"
      })

    block_ref = make_ref()

    owner_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), block_ref: block_ref)

    {:ok, owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: session.id,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id,
        upstream: owner_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _owner_upstream_pid}
    owner_ref = Process.monitor(owner)
    lease = active_owner_lease(session.id)
    %{request: request, attempt: attempt, turn: turn} = active_turn_fixture(setup, auth, session)
    accept_fixture_owner_request!(owner, session, request, attempt, block_ref)

    assert :ok = GenServer.stop(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert released_owner_lease(session.id, lease.lease_token).metadata["release_reason"] ==
             "owner_drained"

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: session,
      error_code: "owner_drained"
    })
  end

  test "T8 delayed same-token owner cleanup preserves replacement and predecessor rows" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-fallback-turn-survives-terminate",
        owner_instance_id: "fallback-owner.example"
      })

    block_ref = make_ref()

    owner_upstream =
      WebsocketOwnerNodeHarness.fake_upstream_boundary(self(), block_ref: block_ref)

    {:ok, owner} =
      GenServer.start_link(WebsocketOwnerSession,
        codex_session_id: session.id,
        owner_lease_token: session.owner_lease_token,
        owner_instance_id: session.owner_instance_id,
        upstream: owner_upstream
      )

    assert_receive {:websocket_owner_harness_upstream_started, _owner_upstream_pid}
    owner_ref = Process.monitor(owner)

    %{request: ws_request, attempt: ws_attempt, turn: ws_turn} =
      active_turn_fixture(setup, auth, session)

    accept_fixture_owner_request!(owner, session, ws_request, ws_attempt, block_ref)

    %{request: fallback_request, attempt: fallback_attempt, turn: fallback_turn} =
      active_turn_fixture(setup, auth, session, "http_sse")

    assert :ok = GenServer.stop(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert Repo.reload!(ws_request).status == "in_progress"
    assert Repo.reload!(ws_attempt).status == "in_progress"
    assert Repo.reload!(ws_turn).status == "in_progress"

    surviving_request = Repo.get!(Request, fallback_request.id)
    surviving_attempt = Repo.get!(Attempt, fallback_attempt.id)
    surviving_turn = Repo.get!(CodexTurn, fallback_turn.id)

    assert surviving_request.status == "in_progress"
    assert is_nil(surviving_request.last_error_code)
    assert surviving_attempt.status == "in_progress"
    assert is_nil(surviving_attempt.network_error_code)
    assert surviving_turn.status == "in_progress"
    assert is_nil(surviving_turn.error_code)
  end

  @tag :owner_interruption_terminal_state
  test "owner interruption preserves a turn after disconnect accounting wins the race" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_disconnect_race"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-disconnect-accounting-race",
          accepted_turn_state: "stable-ws-owner-disconnect-accounting-race",
          client_ip: "127.0.0.1"
        }
      })

    try do
      %{request: request, attempt: attempt, turn: turn, state: state} =
        active_socket_turn_fixture(setup, upstream, state)

      suspend_cleanup_task!(state)

      assert {:ok, %{request: failed_request, attempt: failed_attempt}} =
               Accounting.finalize_request(request, attempt, %{
                 request_status: "failed",
                 attempt_status: "failed",
                 response_status_code: 499,
                 last_error_code: "client_disconnected",
                 error_message: "websocket client disconnected before the turn completed",
                 usage: %{status: "usage_unknown", source: "client_disconnected"}
               })

      assert failed_request.status == "failed"
      assert failed_attempt.status == "failed"
      assert Repo.get!(CodexTurn, turn.id).status == "in_progress"

      interrupt_opts =
        %{
          interrupt_reason: "client_disconnected",
          request_id: request.correlation_id,
          reconnect_window_seconds: 300
        }
        |> RequestOptions.for_websocket()

      assert {:ok, %{interrupted_turn_count: 1}} =
               Interruption.interrupt_codex_session(state.codex_session, interrupt_opts)

      assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: state.codex_session,
        error_code: "client_disconnected"
      })
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :owner_recovery_preserves_success
  test "owner detach recovery preserves already succeeded request attempt and turn" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_recovery_success"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-recovery-success",
          accepted_turn_state: "stable-ws-owner-recovery-success",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "owner_recovery_success_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    remote_node = :"codex_pooler@nodedown-recovery-success.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          Map.put(
            state.opts,
            :websocket_owner_forwarder_opts,
            WebsocketOwnerNodeHarness.node_client_opts([remote_node],
              calls: %{remote_node => :nodedown}
            )
          )
    }

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      refute logs =~ "websocket owner detach failed"
      refute logs =~ "owner_unavailable"
      assert_no_leak!("owner recovery success logs", logs)
      assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "owner detach recovery cleanup remains idempotent after success preservation" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_cleanup_idempotent"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-recovery-cleanup",
          accepted_turn_state: "stable-ws-owner-recovery-cleanup",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    assert {:ok, %{request: succeeded_request, attempt: succeeded_attempt}} =
             Accounting.finalize_request(request, attempt, %{
               request_status: "succeeded",
               attempt_status: "succeeded",
               response_status_code: 200,
               usage: %{status: "usage_unknown", source: "owner_recovery_cleanup_regression"}
             })

    SessionContinuity.complete_codex_turn(
      {:ok, %{request: succeeded_request, attempt: succeeded_attempt}},
      "succeeded",
      nil
    )

    remote_node = :"codex_pooler@nodedown-recovery-cleanup.example"

    remote_state = %{
      state
      | codex_session: %{state.codex_session | owner_instance_id: Atom.to_string(remote_node)},
        opts:
          RequestOptions.for_websocket(%{})
          |> RequestOptions.put_continuity(
            accepted_turn_state: "stable-ws-owner-recovery-cleanup",
            previous_response_id: nil,
            response_id: nil,
            session_header: nil,
            session_key: nil,
            conversation_key: nil,
            owner_instance_id: nil,
            bridge_owner_lease_ttl_seconds: nil,
            reconnect_window_seconds: nil,
            codex_session: nil,
            codex_turn_id: nil,
            authenticated_owner_attach: false
          )
          |> RequestOptions.put_runtime_context(
            now: nil,
            interrupt_reason: nil,
            gateway_debug_payload: nil
          )
          |> RequestOptions.put_transport(
            websocket_owner_forwarder_opts:
              WebsocketOwnerNodeHarness.node_client_opts([remote_node],
                calls: %{remote_node => :nodedown}
              )
          )
    }

    try do
      logs =
        capture_log(fn -> assert :ok = CodexResponsesSocket.terminate(:closed, remote_state) end)

      refute logs =~ "websocket owner detach failed"
      refute logs =~ "owner_unavailable"
      refute logs =~ "Protocol.UndefinedError"
      assert_no_leak!("owner recovery cleanup logs", logs)
      assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn})

      assert :ok =
               CodexResponsesSocket.terminate(
                 :closed,
                 Map.delete(state, :websocket_owner_downstream)
               )
    after
      CodexResponsesSocket.terminate(:closed, Map.delete(state, :websocket_owner_downstream))
    end
  end

  test "remote owner nodedown fails closed without mutating active lease" do
    remote_node = :"codex_pooler@nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-nodedown",
        owner_instance_id: remote_node_string
      })

    lease = active_owner_lease(session.id)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               session,
               session.owner_lease_token,
               %{pid: self(), epoch: 1, correlation_id: "corr-nodedown"},
               Jason.encode!(%{"type" => "response.processed", "response_id" => "resp_nodedown"}),
               opts
             )

    reloaded_lease = Repo.get!(BridgeOwnerLease, lease.id)
    assert reloaded_lease.status == "active"
    assert reloaded_lease.lease_token == lease.lease_token
    assert reloaded_lease.owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner socket init takes over an unavailable remote owner lease" do
    remote_node = :"codex_pooler@init-nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-nodedown",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    state = %{
      auth: auth,
      opts: %{
        request_id: "ws-owner-init-nodedown",
        accepted_turn_state: "stable-ws-owner-init-nodedown",
        client_ip: "127.0.0.1",
        websocket_owner_forwarder_opts: forwarder_opts
      }
    }

    logs =
      capture_info_log(fn ->
        assert {:ok, returned_state} = CodexResponsesSocket.init(state)
        assert returned_state.auth == auth
        assert returned_state.opts.request_id == state.opts.request_id
        assert returned_state.opts.accepted_turn_state == state.opts.accepted_turn_state
        assert returned_state.opts.client_ip == state.opts.client_ip
        assert returned_state.opts.websocket_owner_forwarder_opts == forwarder_opts

        assert returned_state.codex_session.id == session.id
        assert returned_state.codex_session.owner_lease_token != old_lease.lease_token
        assert returned_state.codex_session.owner_instance_id == Atom.to_string(node())

        assert returned_state.websocket_owner_lease_token ==
                 returned_state.codex_session.owner_lease_token

        assert returned_state.websocket_owner_downstream.epoch == 1

        CodexResponsesSocket.terminate(:closed, returned_state)
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    refute logs =~ "pinned_continuation_reauth_required"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=ws-owner-init-nodedown"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_forward_timeout"
    refute logs =~ "owner_crashed"
    assert_no_leak!("owner init nodedown takeover logs", logs)
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
             "owner_unavailable_takeover"

    assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
    assert FakeUpstream.count(upstream) == 0
  end

  test "successful owner socket init takeover stays below warning" do
    remote_node = :"codex_pooler@init-nodedown-warning-owner.example"
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, _session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-warning",
        owner_instance_id: Atom.to_string(remote_node)
      })

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    warning_logs =
      capture_log([level: :warning], fn ->
        assert {:ok, returned_state} =
                 CodexResponsesSocket.init(%{
                   auth: auth,
                   opts: %{
                     request_id: "ws-owner-init-warning",
                     accepted_turn_state: "stable-ws-owner-init-warning",
                     client_ip: "127.0.0.1",
                     websocket_owner_forwarder_opts: forwarder_opts
                   }
                 })

        CodexResponsesSocket.terminate(:closed, returned_state)
      end)

    assert warning_logs == ""
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :owner_forward_timeout
  test "remote owner attach timeout preserves owner_forward_timeout" do
    remote_node = :"codex_pooler@attach-timeout-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-attach-timeout",
        owner_instance_id: remote_node_string
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :timeout}
      )

    assert {:error, :owner_forward_timeout} =
             Gateway.prepare_websocket_session(auth, %{
               accepted_turn_state: "stable-ws-owner-attach-timeout",
               client_ip: "127.0.0.1",
               websocket_owner_forwarder_opts: Keyword.put(opts, :timeout, 25)
             })

    assert_receive {:websocket_owner_harness_node_call,
                    %{function: :remote_attach_downstream, timeout: 25}}

    assert active_owner_lease(session.id).owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :owner_forward_timeout
  test "owner socket init timeout closes normally while preserving owner error detail" do
    remote_node = :"codex_pooler@init-timeout-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-init-timeout",
        owner_instance_id: remote_node_string
      })

    request_id = "ws-owner-init-timeout"

    logs =
      capture_websocket_lifecycle_log(fn ->
        assert :ok =
                 WebsocketConnectionLogger.log_init_failed_before_request_reservation(
                   %{
                     request_id: request_id,
                     endpoint: "/backend-api/codex/responses",
                     transport: "websocket",
                     route_class: "proxy_websocket",
                     phase: "init",
                     elapsed_ms: 17,
                     codex_session_id: session.id,
                     owner_instance_id: remote_node_string,
                     proxy_instance_id: Atom.to_string(node())
                   },
                   :timeout
                 )
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        "websocket init failed before request reservation",
        ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(owner_instance_id proxy_instance_id)
      )

    expected_endpoint = String.replace("/backend-api/codex/responses", ~r/[^a-zA-Z0-9_.:-]+/, "_")
    expected_owner_instance_id = String.replace(remote_node_string, ~r/[^a-zA-Z0-9_.:-]+/, "_")

    expected_proxy_instance_id =
      String.replace(Atom.to_string(node()), ~r/[^a-zA-Z0-9_.:-]+/, "_")

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=#{expected_endpoint}"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "codex_session_id=#{session.id}"
    assert line =~ "owner_instance_id=#{expected_owner_instance_id}"
    assert line =~ "proxy_instance_id=#{expected_proxy_instance_id}"

    assert [] = request_logs(setup.pool.id)

    assert active_owner_lease(session.id).owner_instance_id == remote_node_string
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :owner_forward_nodedown
  test "remote owner attach nodedown takes over lease without leaking erpc details" do
    remote_node = :"codex_pooler@attach-nodedown-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-attach-nodedown",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :raw_nodedown}
      )

    logs =
      capture_info_log(fn ->
        assert {:ok, runtime} =
                 Gateway.prepare_websocket_session(auth, %{
                   accepted_turn_state: "stable-ws-owner-attach-nodedown",
                   client_ip: "127.0.0.1",
                   websocket_owner_forwarder_opts: opts
                 })

        assert runtime.codex_session.id == session.id
        assert runtime.codex_session.owner_lease_token != old_lease.lease_token
        assert runtime.codex_session.owner_instance_id == Atom.to_string(node())
        assert runtime.websocket_owner_downstream.epoch == 1

        Gateway.detach_websocket_owner_downstream(
          runtime.codex_session,
          runtime.websocket_owner_lease_token,
          runtime.websocket_owner_downstream,
          %{websocket_owner_forwarder_opts: opts}
        )
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_forward_timeout"
    refute logs =~ "owner_crashed"
    assert_no_leak!("owner attach nodedown takeover logs", logs)
    assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
             "owner_unavailable_takeover"

    assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
    assert FakeUpstream.count(upstream) == 0
  end

  test "owner takeover failure remains warning and actionable without leaking lease token" do
    remote_node = :"codex_pooler@takeover-failure-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-takeover-failure",
        owner_instance_id: remote_node_string
      })

    old_lease = active_owner_lease(session.id)
    opts = stale_owner_node_client_opts([remote_node])

    logs =
      capture_log([level: :warning], fn ->
        assert {:error, :stale_owner} =
                 Gateway.prepare_websocket_session(auth, %{
                   accepted_turn_state: "stable-ws-owner-takeover-failure",
                   client_ip: "127.0.0.1",
                   websocket_owner_forwarder_opts: opts
                 })
      end)

    assert logs =~ "websocket owner takeover failed"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=investigate"
    assert logs =~ "outcome=failed"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "failure_reason=stale_owner"
    refute logs =~ old_lease.lease_token
    refute logs =~ "operator_action=none"
    assert_no_leak!("owner takeover failure logs", logs)
    assert FakeUpstream.count(upstream) == 0
  end

  test "role-neutral worker and scheduler nodes are not selected as owner targets" do
    remote_worker = :"codex_pooler@10.42.0.20"
    remote_scheduler = :"codex_pooler@10.42.0.21"
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, worker_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-role-worker",
        owner_instance_id: Atom.to_string(remote_worker)
      })

    {:ok, scheduler_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-owner-role-scheduler",
        owner_instance_id: Atom.to_string(remote_scheduler)
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_worker, remote_scheduler],
        roles: %{remote_worker => "worker", remote_scheduler => "scheduler"}
      )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               worker_session,
               worker_session.owner_lease_token,
               downstream_target("corr-role-worker"),
               Jason.encode!(%{
                 "type" => "response.processed",
                 "response_id" => "resp_role_worker"
               }),
               opts
             )

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_frame(
               scheduler_session,
               scheduler_session.owner_lease_token,
               downstream_target("corr-role-scheduler"),
               Jason.encode!(%{
                 "type" => "response.processed",
                 "response_id" => "resp_role_scheduler"
               }),
               opts
             )

    assert_receive {:websocket_owner_harness_app_node_check,
                    %{node: ^remote_worker, role: "worker", app_node?: false}}

    assert_receive {:websocket_owner_harness_app_node_check,
                    %{node: ^remote_scheduler, role: "scheduler", app_node?: false}}

    refute_received {:websocket_owner_harness_node_call, %{node: ^remote_worker}}
    refute_received {:websocket_owner_harness_node_call, %{node: ^remote_scheduler}}
    assert FakeUpstream.count(upstream) == 0
  end

  test "stale owner downstream detach does not remove the newer downstream" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-first",
          accepted_turn_state: "stable-ws-owner-stale",
          client_ip: "127.0.0.1"
        }
      })

    {:ok, second_state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-stale-second",
          accepted_turn_state: "stable-ws-owner-stale",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert first_state.websocket_owner_downstream.epoch == 1
      assert second_state.websocket_owner_downstream.epoch == 2

      assert :ok = CodexResponsesSocket.terminate(:closed, first_state)

      payload = websocket_payload(setup, "after stale detach")

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

      assert {:push, {:text, frame}, second_state} = receive_owner_socket_push(second_state)
      assert %{"id" => "resp_owner_stale"} = Jason.decode!(frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)
    after
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner-forwarded turn takes over when the local owner disappears after socket init" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_dispatch_takeover"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-dispatch-takeover", "dispatch-takeover")
    session = state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}

    try do
      {{:ok, _handled_state, frame}, warning_logs} =
        with_log([level: :warning], fn ->
          payload = websocket_payload(setup, "dispatch takeover")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
          assert {:ok, state} = receive_socket_done(state)

          {:ok, state, frame}
        end)

      assert warning_logs == ""
      assert %{"id" => "resp_owner_dispatch_takeover"} = Jason.decode!(frame)
      assert active_owner_lease(session.id).lease_token == old_lease.lease_token
      assert active_owner_lease(session.id).owner_instance_id == Atom.to_string(node())
      assert [request] = await_upstream_requests(upstream, 1)
      assert request.json["input"] |> List.first() |> Map.get("content") == "dispatch takeover"

      assert Map.new(request.headers)["x-codex-routing-hint"] ==
               "model=#{setup.model.upstream_model_id}"

      assert [request_log] = request_logs(setup.pool.id)
      assert request_log.status == "succeeded"
      assert request_log.response_status_code == 200
      assert is_nil(request_log.last_error_code)

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_log.id))
      assert attempt.status == "succeeded"
      assert attempt.upstream_status_code == 200
      assert is_nil(attempt.network_error_code)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded turn takes over when local owner drained after socket init" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_dispatch_drain_takeover"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} = owner_socket(auth, "ws-owner-dispatch-drain-takeover", "dispatch-drain")
    session = state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    :ok = GenServer.stop(owner_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}

    logs =
      capture_info_log(fn ->
        try do
          payload = websocket_payload(setup, "dispatch drain takeover")

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
          assert %{"id" => "resp_owner_dispatch_drain_takeover"} = Jason.decode!(frame)
          assert {:ok, _state} = receive_socket_done(state)

          active_lease = active_owner_lease(session.id)
          assert active_lease.lease_token != old_lease.lease_token
          assert active_lease.owner_instance_id == Atom.to_string(node())

          assert [request] = await_upstream_requests(upstream, 1)

          assert request.json["input"] |> List.first() |> Map.get("content") ==
                   "dispatch drain takeover"

          assert [request_log] = request_logs(setup.pool.id)
          assert request_log.status == "succeeded"
          assert request_log.response_status_code == 200
          assert is_nil(request_log.last_error_code)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=ws-owner-dispatch-drain-takeover"
    assert logs =~ "previous_owner_instance_id=#{Atom.to_string(node())}"
    refute logs =~ old_lease.lease_token
    refute logs =~ "owner_crashed"

    assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] == "owner_drained"

    assert_no_leak!("local drain dispatch takeover logs", logs)
  end

  test "owner-forwarded socket replaces a local owner with a dead upstream before first dispatch" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_upstream"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, first_state} = owner_socket(auth, "ws-owner-stale-upstream-first", "stale-upstream")
    session = first_state.codex_session
    old_lease = active_owner_lease(session.id)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    owner_ref = Process.monitor(owner_pid)
    %{upstream_pid: upstream_pid} = :sys.get_state(owner_pid)
    upstream_ref = Process.monitor(upstream_pid)
    Process.exit(upstream_pid, :kill)
    assert_receive {:DOWN, ^upstream_ref, :process, ^upstream_pid, :killed}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, _owner_reason}

    {:ok, second_state} = owner_socket(auth, "ws-owner-stale-upstream-second", "stale-upstream")

    try do
      {:ok, replacement_owner_pid} = WebsocketOwnerSession.lookup(session.id)
      assert replacement_owner_pid != owner_pid
      replacement_lease = active_owner_lease(session.id)
      assert replacement_lease.lease_token != old_lease.lease_token
      assert replacement_lease.lease_token == second_state.websocket_owner_lease_token
      assert Repo.get!(BridgeOwnerLease, old_lease.id).status == "released"

      assert Repo.get!(BridgeOwnerLease, old_lease.id).metadata["release_reason"] ==
               "owner_crashed"

      assert second_state.websocket_owner_downstream.epoch == 1

      payload = websocket_payload(setup, "after stale upstream")

      assert {:ok, second_state} =
               CodexResponsesSocket.handle_in({payload, [opcode: :text]}, second_state)

      assert {:push, {:text, frame}, second_state} = receive_owner_socket_push(second_state)
      assert %{"id" => "resp_owner_stale_upstream"} = Jason.decode!(frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [request] = await_upstream_requests(upstream, 1)
      assert request.json["input"] |> List.first() |> Map.get("content") == "after stale upstream"
      assert FakeUpstream.count(upstream) == 1

      assert [request_log] = request_logs(setup.pool.id)
      assert request_log.status == "succeeded"
      assert_forwarding_cardinality!(request_log, session.id, "succeeded")
      refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_id == ^setup.pool.id))
    after
      CodexResponsesSocket.terminate(:closed, first_state)
      CodexResponsesSocket.terminate(:closed, second_state)
    end
  end

  test "owner forwarding keeps authenticated attaches scoped to the same api key" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_auth"}))
    setup = gateway_setup(upstream)
    alternate_key = CodexPooler.PoolerFixtures.api_key_fixture(setup.pool)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-auth"})

    {:ok, alternate_auth} = Access.authenticate_authorization_header(alternate_key.authorization)

    assert Gateway.start_codex_session(alternate_auth, %{
             accepted_turn_state: "stable-ws-auth",
             authenticated_owner_attach: true
           }) == {:error, :owner_unavailable}

    refute Repo.get_by(CodexSession,
             session_key: turn_state_session_key("stable-ws-auth"),
             api_key_id: alternate_key.api_key.id
           )

    refute_raw_turn_state_session_key!(setup.pool.id, "stable-ws-auth")

    assert Repo.get!(CodexSession, session.id).api_key_id == setup.api_key.id
  end

  test "owner forwarding rejects cross-pool and guessed authenticated attaches" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_reject"}))
    setup = gateway_setup(upstream)
    other_key = CodexPooler.PoolerFixtures.api_key_fixture()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-auth-reject"})

    {:ok, other_auth} = Access.authenticate_authorization_header(other_key.authorization)

    assert Gateway.prepare_websocket_session(other_auth, %{
             session_header: session.session_key,
             client_ip: "127.0.0.1"
           }) == {:error, :owner_unavailable}

    assert Gateway.prepare_websocket_session(auth, %{
             session_header: Ecto.UUID.generate(),
             client_ip: "127.0.0.1"
           }) == {:error, :owner_unavailable}

    assert Gateway.prepare_websocket_session(auth, %{
             previous_response_id: "resp_owner_guess",
             client_ip: "127.0.0.1"
           }) == {:error, :owner_unavailable}

    refute Repo.get_by(CodexSession,
             pool_id: other_key.pool.id,
             session_key: session.session_key
           )
  end

  test "owner forwarding rejects a stale bearer before owner attach" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_stale_bearer"}))
    setup = gateway_setup(upstream)

    setup.api_key
    |> APIKey.changeset(%{status: "revoked", revoked_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:error, _reason} = Access.authenticate_authorization_header(setup.authorization)
  end

  @tag :leakage
  test "owner-forwarded success processed and tool continuation keep sentinel out of persisted logs and process state" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => "resp_owner_leak_first"}),
           FakeUpstream.json_response(%{"id" => "resp_owner_leak_processed"}),
           FakeUpstream.json_response(%{"id" => "resp_owner_leak_tool"})
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_log(fn ->
        {:ok, first_state} = owner_socket(auth, "ws-owner-leak-success", "leak-success")

        first_state =
          try do
            first_payload = websocket_payload(setup, @sentinel)

            assert {:ok, first_state} =
                     CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

            assert {:push, {:text, first_frame}, first_state} =
                     receive_owner_socket_push(first_state)

            assert %{"id" => "resp_owner_leak_first"} = Jason.decode!(first_frame)
            assert {:ok, first_state} = receive_socket_done(first_state)
            first_state
          after
            CodexResponsesSocket.terminate(:closed, first_state)
          end

        {:ok, processed_state} = owner_socket(auth, "ws-owner-leak-processed", "leak-success")

        try do
          processed_payload =
            Jason.encode!(%{
              "type" => "response.processed",
              "response_id" => "resp_owner_leak_first",
              "client_context" => @sentinel
            })

          assert {:ok, processed_state} =
                   CodexResponsesSocket.handle_in(
                     {processed_payload, [opcode: :text]},
                     processed_state
                   )

          assert {:ok, processed_state} = receive_owner_socket_complete(processed_state)
          assert {:ok, _processed_state} = receive_socket_done(processed_state)
        after
          CodexResponsesSocket.terminate(:closed, processed_state)
        end

        {:ok, tool_state} = owner_socket(auth, "ws-owner-leak-tool", "leak-success")

        try do
          tool_payload =
            Jason.encode!(%{
              "type" => "response.create",
              "model" => setup.model.exposed_model_id,
              "input" => [
                %{
                  "type" => "function_call_output",
                  "call_id" => "call_owner_leak_tool",
                  "output" => @sentinel
                }
              ],
              "stream" => true,
              "generate" => true,
              "previous_response_id" => "resp_owner_leak_first"
            })

          assert {:ok, tool_state} =
                   CodexResponsesSocket.handle_in({tool_payload, [opcode: :text]}, tool_state)

          assert {:push, {:text, tool_frame}, tool_state} = receive_owner_socket_push(tool_state)
          assert %{"id" => "resp_owner_leak_tool"} = Jason.decode!(tool_frame)
          assert {:ok, _tool_state} = receive_socket_done(tool_state)
        after
          CodexResponsesSocket.terminate(:closed, tool_state)
        end

        assert first_state.codex_session.id
      end)

    assert_no_leak!("success logs", logs)

    assert [first_request, processed_request, tool_request] = await_upstream_requests(upstream, 3)
    assert_leak_allowed_only_in_fake_upstream!(first_request)
    assert_leak_allowed_only_in_fake_upstream!(processed_request)
    assert_leak_allowed_only_in_fake_upstream!(tool_request)
    assert tool_request.json["previous_response_id"] == "resp_owner_leak_first"

    assert tool_request.json["input"] |> List.first() |> Map.get("call_id") ==
             "call_owner_leak_tool"

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert_no_leak_in_persistence!(setup.pool.id)

    {:ok, owner_pid} =
      WebsocketOwnerSession.lookup(
        Repo.get_by!(CodexSession, session_key: turn_state_session_key("leak-success")).id
      )

    assert_no_leak!("owner state after success", :sys.get_state(owner_pid))
  end

  @tag :leakage
  test "owner-forwarded upstream failure keeps sentinel out of logs and accounting rows" do
    upstream =
      start_upstream(
        {:json_error, 500,
         %{
           "error" => %{"code" => "synthetic_upstream_failure", "message" => "synthetic failure"}
         }}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-leak-failure", "leak-failure")

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, error_frame}, _state} = receive_owner_socket_push(state)

          assert %{
                   "type" => "response.failed",
                   "error" => %{"code" => "synthetic_upstream_failure"}
                 } = Jason.decode!(error_frame)

          assert {:ok, _state} = receive_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("failure logs", logs)
    assert [request] = FakeUpstream.requests(upstream)
    assert_leak_allowed_only_in_fake_upstream!(request)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  @tag :leakage
  test "owner raw-frame workers and per-turn response tasks are sensitive while holding sentinel payloads" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-leak-sensitive", "leak-sensitive",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    logs =
      capture_log(fn ->
        try do
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
          assert_sensitive_process_hides_mailbox!(owner_worker_pid)
          assert_sensitive_tracked_response_task!(state)

          send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
          assert {:ok, state} = receive_owner_socket_complete(state)
          assert {:ok, _state} = receive_socket_done(state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("sensitive worker logs", logs)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  test "owner request reservation is finalized when socket closes during upstream work" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-close-during-request", "close-during-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "close while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert state.request_response_work_started?
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate(:closed, state)
        end)

      refute logs =~ WebsocketConnectionLogger.closed_message()
      refute logs =~ WebsocketConnectionLogger.init_failed_message()
      refute logs =~ "websocket owner detach failed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession, session_key: turn_state_session_key("close-during-request"))

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "client_disconnected"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "client_disconnected"
      assert turn.status == "interrupted"
      assert turn.error_code == "client_disconnected"
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  @tag :owner_drained_terminal_state
  test "planned rollout drain during active owner request records owner drained instead of owner crashed" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-rollout-drain-active-request", "rollout-drain-active-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "rollout drain while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          assert :ok = CodexResponsesSocket.terminate({:shutdown, :rollout}, state)
        end)

      refute logs =~ "owner_crashed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("rollout-drain-active-request")
        )

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "owner_drained"
      refute request.last_error_code == "owner_crashed"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "owner_drained"
      refute attempt.network_error_code == "owner_crashed"
      assert turn.status == "interrupted"
      assert turn.error_code == "owner_drained"
      refute turn.error_code == "owner_crashed"

      assert released_owner_lease(
               session.id,
               state.websocket_owner_lease_token
             ).metadata["release_reason"] == "owner_drained"
    after
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  @tag :owner_drained_terminal_state
  test "owner drain persists its exact interruption before replying to the response task" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-rollout-drain-active-request", "rollout-drain-active-request",
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    payload = websocket_payload(setup, "rollout drain while owner request is active")

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    owner_worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    parent = self()
    owner = state.websocket_owner_pid
    original_persistence = :sys.get_state(owner).persistence

    :sys.replace_state(owner, fn current ->
      put_in(current.persistence.interrupt_codex_session, fn session_id, opts ->
        unless Process.get(release_ref, false) do
          Process.put(release_ref, true)
          send(parent, {:owner_interruption_barrier, self(), release_ref})

          receive do
            {:release_owner_interruption, ^release_ref} -> :ok
          after
            15_000 -> raise "owner interruption barrier timed out"
          end
        end

        original_persistence.interrupt_codex_session.(session_id, opts)
      end)
    end)

    try do
      logs =
        capture_websocket_lifecycle_log(fn ->
          drain =
            Task.async(fn ->
              Sandbox.allow(Repo, parent, self())
              CodexResponsesSocket.terminate({:shutdown, :rollout}, state)
            end)

          assert_receive {:owner_interruption_barrier, ^owner, ^release_ref}, 15_000
          assert [%{status: "in_progress", completed_at: nil}] = request_logs(setup.pool.id)

          assert Repo.aggregate(
                   from(l in LedgerEntry,
                     join: r in Request,
                     on: l.request_id == r.id,
                     where: r.pool_id == ^setup.pool.id and l.entry_kind == "settlement"
                   ),
                   :count
                 ) == 0

          send(owner, {:release_owner_interruption, release_ref})
          assert :ok = Task.await(drain, 15_000)
        end)

      refute logs =~ "owner_crashed"
      assert_no_websocket_lifecycle_leaks!(logs)

      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
      assert_response_task_stopped!(state)

      session =
        Repo.get_by!(CodexSession,
          session_key: turn_state_session_key("rollout-drain-active-request")
        )

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      request = Repo.get!(Request, turn.request_id)
      attempt = Repo.one!(from(a in Attempt, where: a.request_id == ^request.id))

      assert request.status == "failed"
      assert request.response_status_code == 499
      assert request.last_error_code == "owner_drained"
      refute request.last_error_code == "owner_crashed"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "owner_drained"
      refute attempt.network_error_code == "owner_crashed"
      assert turn.status == "interrupted"
      assert turn.error_code == "owner_drained"
      refute turn.error_code == "owner_crashed"

      assert released_owner_lease(
               session.id,
               state.websocket_owner_lease_token
             ).metadata["release_reason"] == "owner_drained"
    after
      send(owner, {:release_owner_interruption, release_ref})
      send(owner_worker_pid, {:blocking_owner_upstream_release, release_ref})
    end
  end

  test "owner rollout timeline preserves interrupted and recovered websocket rows" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream(
             [%{"id" => "resp_owner_timeline_interrupted", "object" => "response"}],
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_timeline_recovered",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-owner-rollout-timeline"
    interrupted_request_id = "ws-owner-timeline-interrupted"
    recovered_request_id = "ws-owner-timeline-recovered"

    {:ok, state} = owner_socket(auth, interrupted_request_id, turn_state)

    payload =
      websocket_payload(setup, "owner timeline interrupted", %{
        "request_id" => interrupted_request_id
      })

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref}, 1_000

    assert_receive {:websocket_owner_cleanup_witness, _, _, _, _} = cleanup_message,
                   @handoff_detection_timeout_ms

    assert {:ok, state} = CodexResponsesSocket.handle_info(cleanup_message, state)

    assert [interrupted_upstream_request] = await_upstream_requests(upstream, 1)

    assert interrupted_upstream_request.json["input"] |> List.first() |> Map.get("content") ==
             "owner timeline interrupted"

    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    interrupted_request =
      Repo.one!(
        from r in Request,
          where: r.pool_id == ^setup.pool.id
      )

    assert_native_turn_correlation!(interrupted_request.correlation_id)

    interrupted_attempt =
      Repo.one!(from a in Attempt, where: a.request_id == ^interrupted_request.id)

    interrupted_turn =
      Repo.one!(from t in CodexTurn, where: t.request_id == ^interrupted_request.id)

    session = Repo.get_by!(CodexSession, session_key: turn_state_session_key(turn_state))
    refute_raw_turn_state_session_key!(setup.pool.id, turn_state)

    assert_owner_interruption_state!(%{
      request: interrupted_request,
      attempt: interrupted_attempt,
      turn: interrupted_turn,
      session: session,
      error_code: "client_disconnected"
    })

    remote_node = :"codex_pooler@timeline-unavailable-owner.example"
    remote_node_string = Atom.to_string(remote_node)
    old_lease = active_owner_lease(session.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session
    |> Ecto.Changeset.change(%{owner_instance_id: remote_node_string, updated_at: now})
    |> Repo.update!()

    old_lease
    |> Ecto.Changeset.change(%{owner_instance_id: remote_node_string, updated_at: now})
    |> Repo.update!()

    forwarder_opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :nodedown}
      )

    logs =
      capture_info_log(fn ->
        {:ok, recovered_state} =
          owner_socket(auth, recovered_request_id, turn_state,
            websocket_owner_forwarder_opts: forwarder_opts
          )

        try do
          recovered_payload =
            websocket_payload(setup, "owner timeline recovered", %{
              "request_id" => recovered_request_id
            })

          assert {:ok, recovered_state} =
                   CodexResponsesSocket.handle_in(
                     {recovered_payload, [opcode: :text]},
                     recovered_state
                   )

          assert {:push, {:text, recovered_frame}, recovered_state} =
                   receive_owner_socket_push(recovered_state)

          assert %{"id" => "resp_owner_timeline_recovered"} = Jason.decode!(recovered_frame)
          assert {:ok, _recovered_state} = receive_socket_done(recovered_state)
        after
          CodexResponsesSocket.terminate(:closed, recovered_state)
        end
      end)

    assert logs =~ "websocket owner takeover attempted"
    assert logs =~ "websocket owner takeover succeeded"
    assert logs =~ "recovery_class=owner_unavailable_takeover"
    assert logs =~ "operator_action=none"
    assert logs =~ "outcome=attempting"
    assert logs =~ "outcome=succeeded"
    assert logs =~ "codex_session_id=#{session.id}"
    assert logs =~ "request_id=#{recovered_request_id}"
    assert logs =~ "owner_instance_id=#{remote_node_string}"
    assert logs =~ "proxy_instance_id=#{Atom.to_string(node())}"
    assert logs =~ "previous_owner_instance_id=#{remote_node_string}"
    refute logs =~ old_lease.lease_token
    assert_no_leak!("owner rollout timeline takeover logs", logs)

    released_lease = Repo.get!(BridgeOwnerLease, old_lease.id)
    assert released_lease.status == "released"
    assert released_lease.metadata["release_reason"] == "owner_unavailable_takeover"

    active_lease = active_owner_lease(session.id)
    assert active_lease.owner_instance_id == Atom.to_string(node())
    assert active_lease.metadata["source"] == "owner_unavailable_takeover"

    recovered_request =
      Repo.one!(
        from r in Request,
          where: r.pool_id == ^setup.pool.id and r.id != ^interrupted_request.id
      )

    assert_native_turn_correlation!(recovered_request.correlation_id)

    recovered_attempt = Repo.one!(from a in Attempt, where: a.request_id == ^recovered_request.id)
    recovered_turn = Repo.one!(from t in CodexTurn, where: t.request_id == ^recovered_request.id)

    assert Repo.get!(Request, interrupted_request.id).status == "failed"
    assert Repo.get!(Request, interrupted_request.id).response_status_code == 499
    assert Repo.get!(Request, interrupted_request.id).last_error_code == "client_disconnected"
    assert Repo.get!(Attempt, interrupted_attempt.id).status == "failed"
    assert Repo.get!(Attempt, interrupted_attempt.id).network_error_code == "client_disconnected"
    assert Repo.get!(CodexTurn, interrupted_turn.id).status == "interrupted"
    assert Repo.get!(CodexTurn, interrupted_turn.id).error_code == "client_disconnected"

    assert recovered_request.status == "succeeded"
    assert recovered_request.response_status_code == 200
    assert is_nil(recovered_request.last_error_code)
    assert recovered_attempt.status == "succeeded"
    assert recovered_attempt.upstream_status_code == 200
    assert is_nil(recovered_attempt.network_error_code)
    assert recovered_turn.status == "succeeded"
    assert is_nil(recovered_turn.error_code)
    assert recovered_turn.final_attempt_id == recovered_attempt.id

    assert [first_upstream_request, second_upstream_request] =
             await_upstream_requests(upstream, 2)

    assert Enum.map([first_upstream_request, second_upstream_request], fn request ->
             request.json["input"] |> List.first() |> Map.get("content")
           end) == ["owner timeline interrupted", "owner timeline recovered"]

    assert FakeUpstream.count(upstream) == 2
  end

  @tag :leakage
  test "owner remote wrapper and process crash paths sanitize sentinel-bearing frames" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    remote_timeout = :"codex_pooler@timeout-leak.example"
    remote_crash = :"codex_pooler@crash-leak.example"

    {:ok, timeout_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "leak-remote-timeout",
        owner_instance_id: Atom.to_string(remote_timeout)
      })

    {:ok, crash_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "leak-remote-crash",
        owner_instance_id: Atom.to_string(remote_crash)
      })

    opts =
      WebsocketOwnerNodeHarness.node_client_opts([remote_timeout, remote_crash],
        calls: %{remote_timeout => :timeout, remote_crash => :crash}
      )

    logs =
      capture_log(fn ->
        timeout_result =
          WebsocketOwnerForwarder.submit_frame(
            timeout_session,
            timeout_session.owner_lease_token,
            downstream_target("corr-timeout-leak"),
            @sentinel,
            Keyword.put(opts, :timeout, 25)
          )

        crash_result =
          WebsocketOwnerForwarder.submit_frame(
            crash_session,
            crash_session.owner_lease_token,
            downstream_target("corr-crash-leak"),
            @sentinel,
            opts
          )

        assert timeout_result == {:error, :owner_forward_timeout}
        assert crash_result == {:error, :owner_crashed}
        assert_no_leak!("remote timeout result", timeout_result)
        assert_no_leak!("remote crash result", crash_result)
      end)

    assert_no_leak!("remote wrapper logs", logs)

    Enum.each([:remote_submit_frame, :remote_submit_frame], fn function ->
      assert_receive {:websocket_owner_harness_node_call, %{function: ^function} = call}
      assert_no_leak!("remote call observation", call)
    end)

    owner_crash_logs =
      capture_log(fn ->
        upstream_boundary = crashing_owner_upstream_boundary(self())

        {:ok, owner_pid} =
          WebsocketOwnerSession.start_owner(
            codex_session_id: "synthetic-leak-owner-#{System.unique_integer([:positive])}",
            owner_lease_token: Ecto.UUID.generate(),
            owner_instance_id: Atom.to_string(node()),
            upstream: upstream_boundary
          )

        {:ok, downstream} =
          WebsocketOwnerSession.attach_downstream(
            owner_pid,
            downstream_target("corr-owner-crash")
          )

        assert WebsocketOwnerSession.submit_frame(owner_pid, downstream, @sentinel) ==
                 {:error, :owner_crashed}

        assert_receive {:crashing_owner_upstream_received, upstream_pid}

        assert_receive {:websocket_owner_frame, "corr-owner-crash", 1,
                        {:error, :owner_crashed, safe_payload}}

        assert safe_payload.metadata.reason == "owner_crashed"
        assert_no_leak!("owner crash payload", safe_payload)
        assert_no_leak!("owner state after crash", :sys.get_state(owner_pid))
        assert_no_leak!("crashing owner upstream state", crashing_owner_safe_state(upstream_pid))
      end)

    assert_no_leak!("owner crash logs", owner_crash_logs)

    per_turn_logs =
      capture_log(fn ->
        {:ok, state} = owner_socket(auth, "ws-owner-leak-worker-crash", "leak-worker-crash")

        try do
          crash_state = %{state | auth: %{}}
          payload = websocket_payload(setup, @sentinel)

          assert {:ok, crash_state} =
                   CodexResponsesSocket.handle_in({payload, [opcode: :text]}, crash_state)

          assert {:push, {:text, error_frame}, _state} = receive_socket_done(crash_state)

          assert %{
                   "type" => "error",
                   "error" => %{"code" => "websocket_response_task_failed"}
                 } = Jason.decode!(error_frame)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end)

    assert_no_leak!("per-turn worker crash logs", per_turn_logs)
    assert_no_leak_in_persistence!(setup.pool.id)
  end

  defp websocket_payload(setup, content, extra \\ %{}) do
    websocket_input_payload(
      setup,
      [%{"type" => "message", "role" => "user", "content" => content}],
      extra
    )
  end

  defp websocket_input_payload(setup, input, extra \\ %{}) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true,
      "generate" => true
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp public_stream_payload(setup, input) do
    %{"model" => setup.model.exposed_model_id, "input" => input, "stream" => true}
  end

  defp start_remote_bridge_owner!(auth, session_header, remote_node, persistence_kind \\ :fake) do
    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        session_header: session_header,
        session_header_source: "x-session-id",
        owner_instance_id: Atom.to_string(remote_node)
      })

    persistence =
      case persistence_kind do
        :fake ->
          :erpc.call(remote_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

        :real ->
          :erpc.call(remote_node, WebsocketOwnerNodeHarness, :real_persistence_boundary, [])
      end

    {:ok, owner_pid} =
      :erpc.call(remote_node, WebsocketOwnerSession, :start_owner, [
        [
          codex_session_id: session.id,
          owner_lease_token: session.owner_lease_token,
          owner_instance_id: session.owner_instance_id,
          owner_renewal_ms: 60_000,
          persistence: persistence
        ]
      ])

    on_exit(fn ->
      if remote_node in Node.list(:connected) and
           :erpc.call(remote_node, Process, :alive?, [owner_pid]) do
        owner_monitor = Process.monitor(owner_pid)
        :erpc.call(remote_node, GenServer, :stop, [owner_pid, :normal, 5_000])

        assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :normal},
                       @handoff_detection_timeout_ms
      end
    end)

    {session, owner_pid}
  end

  defp start_bridge_peer!(release, identity, opts \\ [])
       when release in [:current, :previous] and is_struct(identity, UpstreamIdentity) do
    peer_name = String.to_atom("public_owner_#{release}_#{System.unique_integer([:positive])}")

    assert {:ok, peer_pid, peer_node} =
             :peer.start_link(%{
               name: peer_name,
               args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
             })

    Process.unlink(peer_pid)

    on_exit(fn ->
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
      await_peer_down!(peer_name, peer_node)
    end)

    assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    signing_config =
      :codex_pooler
      |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
      |> Keyword.take([:secret_key_base])

    assert :ok =
             :erpc.call(peer_node, Application, :put_env, [
               :codex_pooler,
               CodexPoolerWeb.Endpoint,
               signing_config
             ])

    assert {:ok, runtime_pid} =
             :erpc.call(peer_node, WebsocketOwnerNodeHarness, :start_owner_runtime, [])

    assert node(runtime_pid) == peer_node

    if Keyword.get(opts, :repo) == :real do
      repo_config =
        :codex_pooler
        |> Application.fetch_env!(Repo)
        |> Keyword.merge(pool: DBConnection.ConnectionPool, pool_size: 2)

      assert is_pid(:erpc.call(peer_node, WebsocketOwnerNodeHarness, :start_repo, [repo_config]))

      upstream_config = Application.get_env(:codex_pooler, Upstreams, [])

      assert :ok =
               :erpc.call(peer_node, Application, :put_env, [
                 :codex_pooler,
                 Upstreams,
                 upstream_config
               ])
    end

    on_exit(fn ->
      if remote_node_connected?(peer_node) and
           :erpc.call(peer_node, Process, :alive?, [runtime_pid]) do
        send(runtime_pid, :stop)
      end
    end)

    case release do
      :current ->
        assert {:module, CodexPooler.Upstreams} =
                 WebsocketOwnerPreviousReleaseFixture.load_synthetic_identity_lookup(
                   peer_node,
                   identity.id
                 )

        trace_remote_v1_calls!(peer_node)

      :previous ->
        assert {:module, WebsocketOwnerForwarder} =
                 WebsocketOwnerPreviousReleaseFixture.load_pre_v1_bridge_forwarder(peer_node)

        refute :erpc.call(peer_node, :erlang, :function_exported, [
                 WebsocketOwnerForwarder,
                 :remote_submit_request_v1,
                 3
               ])
    end

    peer_node
  end

  defp stop_remote_owner!(remote_node, codex_session_id, owner_pid) do
    owner_monitor = Process.monitor(owner_pid)

    assert :ok =
             :erpc.call(
               remote_node,
               WebsocketOwnerNodeHarness,
               :stop_owner,
               [codex_session_id, @handoff_detection_timeout_ms],
               @handoff_detection_timeout_ms
             )

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, _reason},
                   @handoff_detection_timeout_ms

    assert :erpc.call(remote_node, WebsocketOwnerNodeHarness, :owner_absent?, [codex_session_id])
    assert Repo.get_by!(BridgeOwnerLease, codex_session_id: codex_session_id).status == "released"
  end

  defp trace_remote_v1_calls!(peer_node) do
    assert {:ok, tracer} =
             :erpc.call(
               peer_node,
               WebsocketOwnerPreviousReleaseFixture,
               :start_forwarder_v1_trace,
               [self()]
             )

    assert node(tracer) == peer_node
  end

  defp public_stream_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      assert [event] = Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first)
      assert [data] = Regex.run(~r/^data: (.+)$/m, block, capture: :all_but_first)
      %{"event" => event, "data" => Jason.decode!(data)}
    end)
  end

  defp assert_bridge_v1_submission!(remote_node) do
    assert_receive {:remote_forwarder_v1_call, remote_pid,
                    [codex_session_id, downstream, %WebsocketOwnerRequest{version: 1} = request]}

    assert node(remote_pid) == remote_node
    assert is_binary(codex_session_id)
    assert %{pid: pid, correlation_id: correlation_id, epoch: epoch} = downstream
    assert is_pid(pid)
    assert is_binary(correlation_id)
    assert is_integer(epoch) and epoch > 0
    assert :ok = WebsocketOwnerRequest.validate(request)
    refute contains_function?(request)
    request
  end

  defp assert_forwarding_cardinality!(request, codex_session_id, status) do
    {request, attempt, turn, settlement, fact} =
      await_forwarding_persistence!(request.id, codex_session_id, status)

    assert Repo.aggregate(from(r in Request, where: r.id == ^request.id), :count) == 1
    assert attempt.status == status
    assert settlement.attempt_id == attempt.id
    assert turn.status == status
    assert turn.final_attempt_id == attempt.id
    assert fact.latest_attempt_id == attempt.id
    assert fact.latest_attempt_number == 1
    assert fact.latest_attempt_status == status
    assert fact.latest_settlement_entry_id == settlement.id
    assert request.retry_count == 0
    assert attempt.attempt_number == 1

    assert Repo.aggregate(from(f in RequestLogFact, where: f.request_id == ^request.id), :count) ==
             1

    {request, attempt, turn, settlement, fact}
  end

  defp await_forwarding_persistence!(request_id, codex_session_id, status, attempts \\ 1_000)

  defp await_forwarding_persistence!(_request_id, _codex_session_id, _status, 0) do
    flunk("expected finalized forwarding persistence")
  end

  defp await_forwarding_persistence!(request_id, codex_session_id, status, attempts) do
    request = Repo.get(Request, request_id)
    request_attempts = Repo.all(from(a in Attempt, where: a.request_id == ^request_id))

    settlements =
      Repo.all(
        from(e in LedgerEntry,
          where: e.request_id == ^request_id and e.entry_kind == "settlement"
        )
      )

    turns = Repo.all(forwarding_turn_query(request_id, codex_session_id))
    fact = Repo.get(RequestLogFact, request_id)

    case {request, request_attempts, turns, settlements, fact} do
      {%Request{status: ^status, completed_at: %DateTime{}} = request,
       [%Attempt{status: ^status, completed_at: %DateTime{}} = attempt],
       [%CodexTurn{status: ^status, completed_at: %DateTime{}} = turn],
       [%LedgerEntry{} = settlement], %RequestLogFact{} = fact}
      when settlement.attempt_id == attempt.id and turn.final_attempt_id == attempt.id and
             fact.latest_attempt_id == attempt.id and
             fact.latest_settlement_entry_id == settlement.id ->
        {request, attempt, turn, settlement, fact}

      _not_finalized ->
        yield_once({:await_forwarding_persistence, request_id, attempts})
        await_forwarding_persistence!(request_id, codex_session_id, status, attempts - 1)
    end
  end

  defp forwarding_turn_query(request_id, nil),
    do: from(t in CodexTurn, where: t.request_id == ^request_id)

  defp forwarding_turn_query(request_id, codex_session_id),
    do:
      from(t in CodexTurn,
        where: t.request_id == ^request_id and t.codex_session_id == ^codex_session_id
      )

  defp assert_no_markers_persisted!(rows, pool_id, markers) do
    {request, _attempt, turn, _settlement, _fact} = rows

    session_ids =
      [turn.codex_session_id]
      |> Enum.reject(&is_nil/1)

    persisted = %{
      request_rows: rows,
      ledger_entries: Repo.all(from(e in LedgerEntry, where: e.request_id == ^request.id)),
      sessions: Repo.all(from(s in CodexSession, where: s.id in ^session_ids)),
      owner_leases:
        Repo.all(from(l in BridgeOwnerLease, where: l.codex_session_id in ^session_ids)),
      session_aliases:
        Repo.all(from(a in BridgeSessionAlias, where: a.codex_session_id in ^session_ids)),
      demotions: Repo.all(from(d in BridgeDemotion, where: d.pool_id == ^pool_id)),
      circuits: Repo.all(from(c in RoutingCircuitState, where: c.pool_id == ^pool_id)),
      request_log: Accounting.list_request_logs(pool_id, filters: %{request_id: request.id})
    }

    persisted = inspect(persisted)
    Enum.each(markers, &refute(persisted =~ &1))
  end

  defp ensure_epmd_started! do
    case :erl_epmd.names() do
      {:ok, _names} ->
        :ok

      {:error, _reason} ->
        assert {_output, 0} = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
        await_epmd!(System.monotonic_time(:millisecond) + @epmd_ready_timeout_ms)
    end
  end

  defp await_epmd!(deadline) do
    case :erl_epmd.names() do
      {:ok, _names} ->
        :ok

      {:error, _reason} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            @epmd_ready_poll_ms -> await_epmd!(deadline)
          end
        else
          flunk("EPMD did not become ready: #{inspect(error)}")
        end
    end
  end

  defp ensure_test_distribution_started! do
    ensure_epmd_started!()
    start_test_distribution!(node())
  end

  defp start_test_distribution!(:nonode@nohost) do
    previous_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
    Application.put_env(:kernel, :prevent_overlapping_partitions, false)
    node_name = String.to_atom("controller_owner_test_#{System.unique_integer([:positive])}")
    assert {:ok, net_kernel_pid} = :net_kernel.start([node_name, :shortnames])

    on_exit(fn ->
      monitor = Process.monitor(net_kernel_pid)
      assert :ok = :net_kernel.stop()

      assert_receive {:DOWN, ^monitor, :process, ^net_kernel_pid, _reason},
                     @handoff_detection_timeout_ms

      await_local_node_stopped!()

      case previous_partition_guard do
        {:ok, value} -> Application.put_env(:kernel, :prevent_overlapping_partitions, value)
        :error -> Application.delete_env(:kernel, :prevent_overlapping_partitions)
      end
    end)
  end

  defp start_test_distribution!(_distributed_node), do: :ok

  defp await_local_node_stopped!(attempts \\ 1_000)

  defp await_local_node_stopped!(0), do: flunk("local distribution did not stop")

  defp await_local_node_stopped!(attempts) do
    if node() == :nonode@nohost do
      :ok
    else
      yield_once({:await_local_node_stopped, attempts})
      await_local_node_stopped!(attempts - 1)
    end
  end

  defp remote_node_connected?(peer_node), do: peer_node in Node.list(:connected)

  defp await_peer_down!(peer_name, peer_node, attempts \\ 1_000)

  defp await_peer_down!(_peer_name, _peer_node, 0), do: flunk("peer did not stop")

  defp await_peer_down!(peer_name, peer_node, attempts) do
    {:ok, names} = :erl_epmd.names()

    if peer_node not in Node.list(:connected) and
         not Enum.any?(names, fn {name, _port} -> name == Atom.to_charlist(peer_name) end) do
      :ok
    else
      yield_once({:await_peer_down, peer_name, attempts})
      await_peer_down!(peer_name, peer_node, attempts - 1)
    end
  end

  test "direct owner continuity chains three settled turns on one upstream connection" do
    assert_owner_three_turn_continuity_chain(:direct)
  end

  test "proxy owner continuity chains three settled turns on one upstream connection" do
    assert_owner_three_turn_continuity_chain(:proxy)
  end

  test "owner completion helper waits through response task control messages" do
    task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(task_pid) end)
    token = make_ref()
    active_turn_ref = make_ref()
    probe_ref = make_ref()

    base_state = %{
      opts: RequestOptions.for_websocket(%{}),
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      public_response_task_pid: nil,
      public_turn_aborted?: false,
      public_turn_owner_complete?: false,
      native_turn_output_task_pids: MapSet.new(),
      native_owner_terminal_delivered?: false,
      websocket_owner_active_turn_reconnect?: true,
      response_task_activities: %{task_pid => token},
      response_task_delivery_scheduled: MapSet.new(),
      response_task_delivery_recipients: %{},
      websocket_owner_downstream: %{
        pid: self(),
        epoch: 41,
        correlation_id: "owner-helper-control",
        active_turn_reconnect?: true
      }
    }

    wrong_task_pid = socket_test_task()
    on_exit(fn -> stop_socket_test_task(wrong_task_pid) end)

    messages = [
      {:websocket_owner_frame, "owner-helper-control", 40, task_pid, :complete},
      {:websocket_owner_frame, "owner-helper-control", 41, wrong_task_pid, :complete},
      {:websocket_owner_frame, "owner-helper-control", 41, task_pid, {:invalid, "ignored"}},
      {:websocket_owner_frame, "owner-helper-control", 41, task_pid,
       {:data, Jason.encode!(%{"type" => "response.output_text.delta"})}},
      {:websocket_owner_output_commit_probe, "owner-helper-control", 41, task_pid,
       active_turn_ref, self(), probe_ref},
      {:websocket_response_activity, task_pid, token},
      {:codex_response_done, task_pid, :ok},
      {:websocket_owner_frame, "owner-helper-control", 41, task_pid,
       {:data, Jason.encode!(%{"type" => "response.completed"})}},
      {:websocket_response_delivery_complete, task_pid, token},
      {:websocket_owner_frame, "owner-helper-control", 41, task_pid, :complete}
    ]

    Enum.each(messages, &send(self(), &1))

    assert {:ok, completed_state} = receive_owner_socket_complete(base_state)
    refute completed_state.websocket_owner_active_turn_reconnect?
    assert completed_state.native_owner_terminal_delivered?

    receive do
      {:websocket_owner_output_commit_ack, _, _, _, _, _, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp assert_owner_three_turn_continuity_chain(route) do
    response_ids =
      Enum.map(1..3, fn turn ->
        "resp_owner_three_turn_#{route}_#{turn}_#{System.unique_integer([:positive])}"
      end)

    upstream =
      start_upstream(
        {:sequence,
         Enum.map(response_ids, fn response_id ->
           FakeUpstream.json_response(%{"id" => response_id, "object" => "response"})
         end)}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "owner-three-turn-#{route}-#{System.unique_integer([:positive])}"

    {:ok, state} =
      owner_socket(auth, "ws-owner-three-turn-#{route}", turn_state)

    state = maybe_proxy_owner_state(state, route)

    try do
      state = run_owner_three_turn_chain(response_ids, route, auth, state, setup)

      assert FakeUpstream.count(upstream) == 3
      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [first_upstream_request, second_upstream_request, third_upstream_request] =
               await_upstream_requests(upstream, 3)

      assert Enum.uniq(
               Enum.map(
                 [first_upstream_request, second_upstream_request, third_upstream_request],
                 & &1.websocket_connection_id
               )
             )
             |> length() == 1

      refute Map.has_key?(first_upstream_request.json, "previous_response_id")
      assert second_upstream_request.json["previous_response_id"] == Enum.at(response_ids, 0)
      assert third_upstream_request.json["previous_response_id"] == Enum.at(response_ids, 1)

      assert [first_request, second_request, third_request] = request_logs(setup.pool.id)

      assert_three_turn_persistence(
        [first_request, second_request, third_request],
        response_ids,
        state.codex_session.id
      )

      correlations = Enum.map([first_request, second_request, third_request], & &1.correlation_id)
      Enum.each(correlations, &assert_native_turn_correlation!/1)
      assert length(Enum.uniq(correlations)) == 3

      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp run_owner_three_turn_chain(response_ids, route, auth, state, setup) do
    response_ids
    |> Enum.with_index(1)
    |> Enum.reduce({state, nil}, fn {response_id, turn}, {state, previous_response_id} ->
      request_id = "ws-owner-three-turn-#{route}-#{turn}"
      extra = owner_continuation_extra(request_id, previous_response_id)
      payload = websocket_payload(setup, "owner three turn #{route} #{turn}", extra)

      state = run_owner_continuity_turn(route, auth, state, payload)
      assert {:push, {:text, frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(frame) == response_id
      assert {:ok, state} = receive_owner_continuity_complete(route, state)

      assert %{active_turn: nil} =
               :sys.get_state(WebsocketOwnerSession.lookup(state.codex_session.id) |> elem(1))

      {state, response_id}
    end)
    |> elem(0)
  end

  defp owner_continuation_extra(request_id, nil), do: %{"request_id" => request_id}

  defp owner_continuation_extra(request_id, previous_response_id) do
    %{"request_id" => request_id, "previous_response_id" => previous_response_id}
  end

  defp assert_three_turn_persistence(requests, response_ids, codex_session_id) do
    for {request, response_id} <- Enum.zip(requests, response_ids) do
      assert request.status == "succeeded"
      assert_request_settled_once(request)
      assert_active_response_alias(codex_session_id, response_id)
    end
  end

  defp assert_request_settled_once(request) do
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1

    assert Repo.aggregate(
             from(a in Attempt, where: a.request_id == ^request.id and a.status == "succeeded"),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^request.id), :count) == 1

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.request_id == ^request.id and t.status == "succeeded"),
             :count
           ) == 1
  end

  defp assert_active_response_alias(codex_session_id, response_id) do
    assert Repo.aggregate(
             from(alias_record in BridgeSessionAlias,
               where:
                 alias_record.codex_session_id == ^codex_session_id and
                   alias_record.alias_kind == "previous_response_id" and
                   alias_record.alias_hash == ^:crypto.hash(:sha256, response_id) and
                   alias_record.status == "active"
             ),
             :count
           ) == 1
  end

  defp run_owner_continuity_turn(:direct, _auth, state, payload) do
    case CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state) do
      {:ok, state} -> state
    end
  end

  defp run_owner_continuity_turn(:proxy, auth, state, payload) do
    assert :ok =
             Gateway.run_websocket_response(
               auth,
               payload,
               owner_response_options(state, owner_node_opts(state, :proxy)),
               fn _data -> :ok end
             )

    Map.update(state, :tasks, MapSet.new([self()]), &MapSet.put(&1, self()))
  end

  defp receive_owner_continuity_complete(:direct, state), do: receive_socket_done(state)

  defp receive_owner_continuity_complete(:proxy, state) do
    case receive_owner_socket_complete(state) do
      {:ok, state} -> {:ok, Map.update!(state, :tasks, &MapSet.delete(&1, self()))}
    end
  end

  defp assert_owner_continuation_generation_boundary(route) do
    previous_response_id = "resp_owner_generation_anchor_#{route}"
    private_input = "synthetic private owner continuation #{route}"

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => previous_response_id, "object" => "response"}),
           FakeUpstream.json_response(%{
             "id" => "resp_owner_generation_retry_#{route}",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-generation-#{route}", "owner-generation-#{route}")
    state = maybe_proxy_owner_state(state, route)

    try do
      anchor_payload = websocket_payload(setup, "synthetic owner generation anchor #{route}")
      owner_opts = owner_response_options(state, owner_node_opts(state, route))

      assert :ok =
               Gateway.run_websocket_response(auth, anchor_payload, owner_opts, fn _data ->
                 :ok
               end)

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(anchor_frame) == previous_response_id
      assert {:ok, state} = receive_owner_socket_complete(state)

      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
      upstream_pid = :sys.get_state(owner_pid).upstream_pid
      assert :ok = UpstreamWebsocketSession.invalidate_connection(upstream_pid)

      continuation_payload =
        websocket_payload(setup, private_input, %{
          "previous_response_id" => previous_response_id
        })

      assert :ok =
               Gateway.run_websocket_response(auth, continuation_payload, owner_opts, fn _data ->
                 :ok
               end)

      assert {:push, {:text, retry_terminal}, state} = receive_owner_socket_push(state)
      assert Jason.decode!(retry_terminal) == Jason.decode!(native_owner_retry_terminal())
      assert {:ok, state} = receive_owner_socket_complete(state)
      refute_received {:websocket_owner_frame, _, _, {:data, ^retry_terminal}}
      refute_received {:websocket_owner_frame, _, _, :complete}
      assert FakeUpstream.count(upstream) == 1
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      full_retry_payload = websocket_payload(setup, "synthetic explicit full retry #{route}")

      assert :ok =
               Gateway.run_websocket_response(auth, full_retry_payload, owner_opts, fn _data ->
                 :ok
               end)

      assert {:push, {:text, full_retry_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(full_retry_frame) == "resp_owner_generation_retry_#{route}"
      assert {:ok, _state} = receive_owner_socket_complete(state)

      assert [anchor_upstream_request, full_retry_upstream_request] =
               FakeUpstream.requests(upstream)

      assert anchor_upstream_request.websocket_connection_id !=
               full_retry_upstream_request.websocket_connection_id

      assert FakeUpstream.websocket_connection_count(upstream) == 2

      assert [anchor_request, guarded_request, full_retry_request] = request_logs(setup.pool.id)
      assert anchor_request.status == "succeeded"
      assert guarded_request.status == "failed"
      assert guarded_request.last_error_code == "stream_incomplete"
      assert full_retry_request.status == "succeeded"

      assert [guarded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^guarded_request.id))

      assert guarded_attempt.status == "failed"

      assert guarded_attempt.response_metadata["transport_failure"]["termination_source"] ==
               "continuation_generation_guard"

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where:
                   entry.request_id == ^guarded_request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(t in CodexTurn, where: t.request_id == ^guarded_request.id),
               :count
             ) ==
               1

      persisted = inspect({guarded_request, guarded_attempt})
      refute persisted =~ previous_response_id
      refute persisted =~ private_input
      refute persisted =~ setup.authorization
      refute persisted =~ retry_terminal
      assert_no_leak_in_persistence!(setup.pool.id)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp assert_receiver_delivery_gap(order) when order in [:frames_first, :cleanup_first] do
    response_id = "resp_receiver_delivery_gap_#{order}_#{System.unique_integer([:positive])}"

    frames = [
      Jason.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => response_id, "status" => "in_progress"}
      }),
      Jason.encode!(%{
        "type" => "response.output_item.done",
        "item" => %{"id" => "item_receiver_delivery_gap", "type" => "message"}
      }),
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        }
      })
    ]

    upstream = start_upstream(FakeUpstream.websocket_text_frames(frames))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    parent = self()

    receiver = spawn(fn -> receiver_delivery_gap_process(parent, order, auth, setup) end)

    receiver_monitor = Process.monitor(receiver)

    try do
      send(receiver, {:receiver_delivery_gap_start, order})

      assert_receive {:receiver_delivery_gap_result, ^order, events, cleanup_snapshot},
                     @handoff_detection_timeout_ms

      assert events == ["response.created", "response.output_item.done", "response.completed"]
      refute_received {:stale_prepared_writer, _data}
      assert cleanup_snapshot == %{monitor_tracked?: false, task_tracked?: false}
      assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, :normal}

      assert [request] = request_logs(setup.pool.id)
      assert request.status == "succeeded"
      assert_forwarding_cardinality!(request, nil, "succeeded")
    after
      if Process.alive?(receiver), do: Process.exit(receiver, :kill)

      case previous do
        :error ->
          Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)

        {:ok, value} ->
          Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end
  end

  defp receiver_delivery_gap_process(parent, order, auth, setup) do
    receive do
      {:receiver_delivery_gap_start, ^order} ->
        {:ok, state} =
          CodexResponsesSocket.init(%{
            auth: auth,
            opts: %{
              request_id: "ws-receiver-delivery-gap-#{order}",
              accepted_turn_state: "receiver-delivery-gap-#{order}",
              client_ip: "127.0.0.1"
            }
          })

        payload = websocket_payload(setup, "receiver delivery gap #{order}")

        opts =
          Gateway.websocket_response_options(
            state.opts,
            state.codex_session,
            state.upstream_websocket_session,
            true
          )

        receiver_pid = self()
        stale_writer = fn data -> send(receiver_pid, {:stale_prepared_writer, data}) end
        {:ok, prepared} = Gateway.prepare_websocket_response(payload, opts, stale_writer)

        {:ok, task_pid} =
          ResponseTask.start(
            receiver_pid,
            :direct,
            fn task_pid ->
              Gateway.run_prepared_websocket_response_for_socket(
                auth,
                prepared,
                fn data -> send(receiver_pid, {:codex_response_chunk, task_pid, data}) end
              )
            end,
            fn _task_pid, :owner_drained -> :ok end
          )

        monitor = Process.monitor(task_pid)

        state = %{
          state
          | tasks: MapSet.new([task_pid]),
            task_monitors: %{task_pid => monitor},
            request_response_work_started?: true
        }

        run_receiver_delivery_gap(parent, order, task_pid, state)
    end
  end

  defp run_receiver_delivery_gap(parent, :frames_first, task_pid, state) do
    {state, events} = receive_receiver_delivery_gap_frames(task_pid, state)
    state = receive_receiver_delivery_gap_result(task_pid, state)
    {:completed, state} = receive_receiver_delivery_gap_completion(task_pid, state)

    send(parent, {
      :receiver_delivery_gap_result,
      :frames_first,
      events,
      receiver_delivery_gap_snapshot(state)
    })

    CodexResponsesSocket.terminate(:closed, state)
  end

  defp run_receiver_delivery_gap(parent, :cleanup_first, task_pid, state) do
    state = receive_receiver_delivery_gap_result(task_pid, state)

    state =
      case receive_receiver_delivery_gap_completion(task_pid, state, 0) do
        {:completed, state} -> state
        {:pending, state} -> state
      end

    {state, events} = receive_receiver_delivery_gap_frames(task_pid, state)
    {:completed, state} = receive_receiver_delivery_gap_completion(task_pid, state)

    send(
      parent,
      {:receiver_delivery_gap_result, :cleanup_first, events,
       receiver_delivery_gap_snapshot(state)}
    )
  end

  defp receive_receiver_delivery_gap_frames(task_pid, state) do
    receive_receiver_delivery_gap_frames(task_pid, state, [])
  end

  defp receive_receiver_delivery_gap_frames(_task_pid, state, events)
       when length(events) == 3,
       do: {state, events}

  defp receive_receiver_delivery_gap_frames(task_pid, state, events) do
    receive do
      {:codex_response_chunk, ^task_pid, data} = message ->
        assert {:push, {:text, pushed}, state} = CodexResponsesSocket.handle_info(message, state)
        assert Jason.decode!(pushed) == Jason.decode!(data)
        event = Jason.decode!(pushed)["type"]

        events =
          if event in ["response.created", "response.output_item.done", "response.completed"],
            do: events ++ [event],
            else: events

        receive_receiver_delivery_gap_frames(task_pid, state, events)
    after
      @handoff_detection_timeout_ms ->
        flunk("expected queued provider frame at the direct receiver")
    end
  end

  defp receive_receiver_delivery_gap_result(task_pid, state) do
    receive do
      {:websocket_response_activity, ^task_pid, _activity_token} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        receive_receiver_delivery_gap_result(task_pid, state)

      {:codex_response_done, ^task_pid, _result} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        state
    after
      @handoff_detection_timeout_ms ->
        flunk("expected response-task result handoff")
    end
  end

  defp receive_receiver_delivery_gap_completion(
         task_pid,
         state,
         timeout \\ @handoff_detection_timeout_ms
       ) do
    receive do
      {:websocket_response_delivery_complete, ^task_pid, _activity_token} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        {:completed, state}
    after
      timeout -> {:pending, state}
    end
  end

  defp receiver_delivery_gap_snapshot(state) do
    %{
      task_tracked?: MapSet.size(state.tasks) > 0,
      monitor_tracked?: map_size(state.task_monitors) > 0
    }
  end

  defp maybe_proxy_owner_state(state, :direct), do: state

  defp maybe_proxy_owner_state(state, :proxy) do
    remote_node = :"codex_pooler@continuation-owner.example"

    remote_owner_state(
      state,
      remote_node,
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )
    )
  end

  defp assert_active_reconnect_frame_matrix(route) when route in [:direct, :proxy] do
    private_sentinel = "REPLAY_ACTIVE_MATRIX_PRIVATE_SENTINEL"
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-active-matrix-#{route}"

    {:ok, first_state} =
      owner_socket(auth, "ws-active-matrix-#{route}-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "active matrix predecessor", %{
        "request_id" => "ws-active-matrix-#{route}-a",
        "client_metadata" => %{"turn_id" => "ws-active-matrix-#{route}-a"}
      })

    assert {:ok, _first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    worker_pid = assert_blocking_owner_upstream_received!(release_ref)
    {:ok, reconnect_state} = owner_socket(auth, "ws-active-matrix-#{route}-b", turn_state)

    reconnect_state = maybe_proxy_owner_state(reconnect_state, route)
    owner_pid = reconnect_state.websocket_owner_pid
    before_owner = :sys.get_state(owner_pid)

    prewarm = Jason.encode!(%{"generate" => false, "model" => setup.model.exposed_model_id})

    {prewarm_result, prewarm_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({prewarm, [opcode: :text]}, reconnect_state)
      end)

    assert {:ok, prewarm_state} = prewarm_result
    assert prewarm_log == ""
    assert length(request_logs(setup.pool.id)) == 1
    assert :sys.get_state(owner_pid).active_turn.descriptor == before_owner.active_turn.descriptor
    assert :sys.get_state(owner_pid).pending_handoff == before_owner.pending_handoff

    assert {:push, {:text, created}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert Jason.decode!(created)["type"] == "response.created"

    assert {:push, {:text, completed}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert Jason.decode!(completed)["type"] == "response.completed"
    assert {:ok, prewarm_state} = receive_socket_done(prewarm_state)

    missing = websocket_payload(setup, private_sentinel)

    {missing_result, missing_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({missing, [opcode: :text]}, prewarm_state)
      end)

    assert {:push, {:text, missing_error}, ^prewarm_state} = missing_result
    assert Jason.decode!(missing_error)["error"]["code"] == "owner_busy"

    assert event_count(missing_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
             1

    assert missing_log =~ "reconnect_disposition=owner_busy"
    refute missing_log =~ private_sentinel

    different =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "ws-active-matrix-#{route}-different",
        "client_metadata" => %{"turn_id" => "ws-active-matrix-#{route}-different"}
      })

    {different_result, different_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({different, [opcode: :text]}, prewarm_state)
      end)

    assert {:push, {:text, different_error}, ^prewarm_state} = different_result

    assert Jason.decode!(different_error)["error"]["code"] == "owner_busy"

    assert event_count(different_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
             1

    assert different_log =~ "reconnect_disposition=owner_busy"
    refute different_log =~ private_sentinel
    refute Map.has_key?(:sys.get_state(owner_pid).active_turn, :canceled_result)

    malformed =
      websocket_payload(setup, private_sentinel, %{
        "request_id" => "fallback-must-not-win",
        "client_metadata" => %{"turn_id" => "invalid/identity"}
      })

    {malformed_result, malformed_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({malformed, [opcode: :text]}, prewarm_state)
      end)

    assert {:push, {:text, malformed_error}, ^prewarm_state} = malformed_result

    assert %{"status" => 400, "error" => %{"code" => "invalid_request", "param" => param}} =
             Jason.decode!(malformed_error)

    assert param == "client_metadata.turn_id"

    assert event_count(malformed_log, WebsocketConnectionLogger.reconnect_disposition_message()) ==
             1

    assert malformed_log =~ "reconnect_disposition=identity_rejected"
    refute malformed_log =~ private_sentinel

    processed =
      Jason.encode!(%{"type" => "response.processed", "response_id" => "resp_active_matrix"})

    assert {:push, {:text, processed_error}, ^prewarm_state} =
             CodexResponsesSocket.handle_in({processed, [opcode: :text]}, prewarm_state)

    assert Jason.decode!(processed_error)["error"]["code"] == "owner_busy"

    public_opts =
      reconnect_state.opts
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

    public_state = %{prewarm_state | opts: public_opts}

    public_payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => private_sentinel
      })

    assert {:push, {:text, public_error}, ^public_state} =
             CodexResponsesSocket.handle_in({public_payload, [opcode: :text]}, public_state)

    assert Jason.decode!(public_error)["error"]["code"] == "owner_busy"
    assert length(request_logs(setup.pool.id)) == 1

    send(worker_pid, {:blocking_owner_upstream_release, release_ref})
    assert {:ok, prewarm_state} = receive_owner_socket_complete(prewarm_state)
    assert {:ok, prewarm_state} = receive_socket_done(prewarm_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, prewarm_state)
  end

  defp assert_pending_replacement_prewarm_neutral(route) when route in [:direct, :proxy] do
    upstream_boundary = reconnect_handoff_owner_upstream_boundary(self())
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-pending-prewarm-#{route}"

    {:ok, first_state} =
      owner_socket(auth, "ws-pending-prewarm-#{route}-a", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    first_payload =
      websocket_payload(setup, "pending prewarm predecessor", %{
        "request_id" => "ws-pending-prewarm-#{route}-a",
        "client_metadata" => %{"turn_id" => "ws-pending-prewarm-#{route}-a"}
      })

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, first_state)

    assert_receive {:controller_handoff_predecessor_started, _pid},
                   @blocking_owner_receive_timeout_ms

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(first_state.codex_session.id)

    assert :ok =
             WebsocketOwnerSession.detach_downstream(
               owner_pid,
               first_state.websocket_owner_downstream
             )

    {:ok, replacement_state} =
      owner_socket(auth, "ws-pending-prewarm-#{route}-b", turn_state,
        websocket_owner_forwarder_opts: [upstream: upstream_boundary]
      )

    replacement_state = maybe_proxy_owner_state(replacement_state, route)

    replacement_payload =
      websocket_payload(setup, "pending prewarm replacement", %{
        "request_id" => "ws-pending-prewarm-#{route}-b",
        "client_metadata" => %{"turn_id" => "ws-pending-prewarm-#{route}-b"}
      })

    assert {:ok, pending_state} =
             CodexResponsesSocket.handle_in(
               {replacement_payload, [opcode: :text]},
               replacement_state
             )

    pending_before = pending_state.websocket_owner_pending_handoff
    owner_pending_before = :sys.get_state(owner_pid).pending_handoff
    prewarm = Jason.encode!(%{"generate" => false, "model" => setup.model.exposed_model_id})

    {prewarm_result, prewarm_log} =
      with_info_log(fn ->
        CodexResponsesSocket.handle_in({prewarm, [opcode: :text]}, pending_state)
      end)

    assert {:ok, prewarm_state} = prewarm_result
    assert prewarm_log == ""
    assert prewarm_state.websocket_owner_pending_handoff == pending_before

    assert :sys.get_state(owner_pid).pending_handoff.control_ref ==
             owner_pending_before.control_ref

    assert length(request_logs(setup.pool.id)) == 1

    assert {:push, {:text, created}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert Jason.decode!(created)["type"] == "response.created"

    assert {:push, {:text, completed}, prewarm_state} =
             receive_native_collect_socket_push(prewarm_state)

    assert Jason.decode!(completed)["type"] == "response.completed"
    assert {:ok, prewarm_state} = receive_socket_done(prewarm_state)
    assert prewarm_state.websocket_owner_pending_handoff == pending_before
    assert length(request_logs(setup.pool.id)) == 1
    CodexResponsesSocket.terminate(:closed, prewarm_state)
    CodexResponsesSocket.terminate(:closed, first_state)
  end

  defp owner_node_opts(_state, :direct), do: []
  defp owner_node_opts(state, :proxy), do: state.opts.websocket_owner_forwarder_opts

  defp native_owner_retry_terminal do
    Jason.encode!(%{
      "type" => "error",
      "status" => 400,
      "error" => %{
        "type" => "invalid_request_error",
        "code" => "previous_response_not_found",
        "message" => "Previous response was not found. Retrying the full request."
      }
    })
  end

  defp model_serving_scope do
    %{user: owner} = CodexPooler.AccountsFixtures.bootstrap_owner_fixture()
    Scope.for_user(owner, ["instance_owner"])
  end

  defp set_model_serving_mode!(scope, setup, mode, expected_revision \\ nil) do
    expected_revision =
      expected_revision ||
        case Pools.model_serving_modes_snapshot(scope, setup.pool) do
          {:ok, snapshot} -> snapshot.revision
          {:error, error} -> flunk("failed to read model serving modes: #{inspect(error)}")
        end

    assert {:ok, result} =
             Pools.update_model_serving_modes(
               scope,
               setup.pool,
               [%{exposed_model_id: setup.model.exposed_model_id, mode: mode}],
               expected_revision
             )

    result.revision
  end

  defp model_serving_owner_payload(setup, label, spoofed_lite_value) do
    websocket_payload(setup, "synthetic owner mode #{label}", %{
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "medium", "context" => "current_turn"},
      "client_metadata" => %{
        @responses_lite_client_metadata_key => spoofed_lite_value,
        "model_serving_mode" => "unknown"
      }
    })
  end

  defp remote_owner_state(state, remote_node, node_opts) do
    %{
      state
      | codex_session: %{
          state.codex_session
          | owner_instance_id: Atom.to_string(remote_node)
        },
        opts: put_owner_node_opts(state.opts, node_opts)
    }
  end

  defp unpinned_remote_owner_state(state, remote_node, node_opts) do
    state = remote_owner_state(state, remote_node, node_opts)

    codex_session =
      state.codex_session
      |> Ecto.Changeset.change(pool_upstream_assignment_id: nil)
      |> Repo.update!()

    %{
      state
      | codex_session: %{codex_session | owner_instance_id: Atom.to_string(remote_node)}
    }
  end

  defp owner_response_options(state, node_opts) do
    Gateway.websocket_owner_response_options(
      put_owner_node_opts(state.opts, node_opts),
      state.codex_session,
      state.websocket_owner_lease_token,
      state.websocket_owner_downstream
    )
  end

  defp reset_probe_usage_upstream do
    start_upstream(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
         "/api/codex/usage" =>
           {200, %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}}
       }}
    )
  end

  defp enable_reset_probe!(identity, usage_upstream) do
    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(usage_upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    prime_weekly_exhausted_quota!(identity)
    identity
  end

  defp put_owner_capacity_quota!(identity, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new(used_percent),
                 reset_at: DateTime.add(now, 2, :hour),
                 observed_at: now,
                 last_sync_at: now,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               }
             ])
  end

  defp assert_reset_probe_usage_calls!(usage_upstream) do
    requests = FakeUpstream.requests(usage_upstream)

    assert [%{method: "POST", json: %{"redeem_request_id" => _}}] =
             Enum.filter(requests, &(&1.path == "/api/codex/rate-limit-reset-credits/consume"))

    assert Enum.any?(requests, &(&1.method == "GET" and &1.path == "/api/codex/usage"))
  end

  defp assert_reset_probe_public_metadata_safe!(request, attempt, redemption, forbidden_values) do
    probe = redemption["probe"]
    persisted = inspect({request.request_metadata, attempt.response_metadata})

    refute persisted =~ probe["token"]
    refute persisted =~ inspect(probe["scope"])
    refute persisted =~ "upstream-token"
    refute Map.has_key?(request.request_metadata, "probe")
    refute Map.has_key?(attempt.response_metadata, "probe")

    Enum.each(forbidden_values, fn forbidden_value ->
      refute persisted =~ forbidden_value
    end)
  end

  defp put_owner_node_opts(%RequestOptions{} = opts, node_opts) do
    RequestOptions.put_transport(opts, websocket_owner_forwarder_opts: node_opts)
  end

  defp put_owner_node_opts(opts, node_opts) when is_map(opts) do
    Map.put(opts, :websocket_owner_forwarder_opts, node_opts)
  end

  defp owner_response_id(frame) do
    decoded = Jason.decode!(frame)
    decoded["id"] || get_in(decoded, ["response", "id"])
  end

  defp assert_remote_submit_request_v1!(state, remote_node, mode \\ nil, timeout \\ 100) do
    codex_session_id = state.codex_session.id
    downstream = state.websocket_owner_downstream

    assert_receive {:websocket_owner_harness_node_call,
                    %{
                      node: ^remote_node,
                      function: :remote_submit_request_v1,
                      arity: 3,
                      codex_session_id: ^codex_session_id,
                      downstream: ^downstream
                    } = call},
                   timeout

    if mode, do: assert(call.mode == mode)

    assert_receive {:websocket_owner_harness_request,
                    %WebsocketOwnerRequest{version: 1} = owner_request},
                   timeout

    assert :ok = WebsocketOwnerRequest.validate(owner_request)
    refute contains_function?(owner_request)
    owner_request
  end

  defp contains_function?(value) when is_function(value), do: true

  defp contains_function?(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> contains_function?()
  end

  defp contains_function?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested_value} ->
      contains_function?(key) or contains_function?(nested_value)
    end)
  end

  defp contains_function?(value) when is_list(value), do: Enum.any?(value, &contains_function?/1)

  defp contains_function?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.any?(&contains_function?/1)
  end

  defp contains_function?(_value), do: false

  defp assert_canonical_lite_owner_request!(captured) do
    assert captured.method == "WEBSOCKET"

    assert get_in(captured.json, ["client_metadata", @responses_lite_client_metadata_key]) ==
             "true"

    assert captured.json["parallel_tool_calls"] == false
    assert get_in(captured.json, ["reasoning", "context"]) == "all_turns"
  end

  defp assert_canonical_full_owner_request!(captured) do
    assert captured.method == "WEBSOCKET"

    refute get_in(captured.json, ["client_metadata", @responses_lite_client_metadata_key])
    assert captured.json["parallel_tool_calls"] == true
    assert get_in(captured.json, ["reasoning", "context"]) == "current_turn"
  end

  defp assert_owner_mode_accounting!(request, mode, status, remote_node) do
    expected = %{
      "model_serving_mode_configured" => mode,
      "model_serving_mode" => mode,
      "model_serving_mode_source" => "override"
    }

    assert request.status == status
    assert request.transport == "websocket"
    assert Map.take(request.request_metadata["routing"], @model_serving_metadata_keys) == expected

    owner_metadata = request.request_metadata["websocket_owner_forwarding"]
    assert owner_metadata["enabled"] == true
    assert owner_metadata["owner_instance_id"] == Atom.to_string(remote_node)
    assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == status
    assert attempt.transport == "websocket"

    assert Map.take(attempt.response_metadata["routing"], @model_serving_metadata_keys) ==
             expected
  end

  defp ensure_previous_response_alias!(
         %CodexSession{} = session,
         %APIKey{} = api_key,
         response_id
       ) do
    alias_hash = :crypto.hash(:sha256, response_id)

    case Repo.get_by(BridgeSessionAlias,
           pool_id: session.pool_id,
           api_key_id: api_key.id,
           alias_kind: "previous_response_id",
           alias_hash: alias_hash,
           status: "active"
         ) do
      %BridgeSessionAlias{} = alias_record ->
        alias_record

      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %BridgeSessionAlias{}
        |> BridgeSessionAlias.changeset(%{
          codex_session_id: session.id,
          pool_id: session.pool_id,
          api_key_id: api_key.id,
          alias_kind: "previous_response_id",
          alias_hash: alias_hash,
          alias_preview: "synthetic-prev",
          status: "active",
          expires_at: DateTime.add(now, 300, :second),
          last_seen_at: now,
          metadata: %{},
          created_at: now,
          updated_at: now
        })
        |> Repo.insert!()
    end
  end

  defp capture_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp with_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      with_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp capture_websocket_lifecycle_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(
        [
          level: :info,
          format: "$metadata$message\n",
          metadata: @websocket_lifecycle_metadata_keys,
          colors: [enabled: false]
        ],
        fun
      )
    after
      Logger.configure(level: previous_level)
    end
  end

  defp stale_owner_node_client_opts(nodes) when is_list(nodes) do
    previous = Process.get(StaleOwnerNodeClient)
    Process.put(StaleOwnerNodeClient, %{nodes: nodes})

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Process.delete(StaleOwnerNodeClient)
        value -> Process.put(StaleOwnerNodeClient, value)
      end
    end)

    [node_client: StaleOwnerNodeClient]
  end

  defp owner_socket(auth, request_id, turn_state, extra_opts \\ []) do
    CodexResponsesSocket.init(%{
      auth: auth,
      opts:
        Map.merge(
          %{
            request_id: request_id,
            accepted_turn_state: turn_state,
            client_ip: "127.0.0.1"
          },
          Map.new(extra_opts)
        )
    })
  end

  defp use_fresh_rollout_drain! do
    previous_config = Application.get_env(:codex_pooler, RolloutDrain)

    previous_status_config =
      Application.get_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

    activity_registry = :"predispatch-activity-#{System.unique_integer([:positive])}"
    drain_name = :"predispatch-drain-#{System.unique_integer([:positive])}"
    start_supervised!({ActivityRegistry, name: activity_registry})
    start_supervised!({RolloutDrain, name: drain_name, activity_registry: activity_registry})
    Application.put_env(:codex_pooler, RolloutDrain, server_name: drain_name)
    Application.delete_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

    on_exit(fn ->
      case previous_config do
        nil -> Application.delete_env(:codex_pooler, RolloutDrain)
        config -> Application.put_env(:codex_pooler, RolloutDrain, config)
      end

      case previous_status_config do
        nil ->
          Application.delete_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

        config ->
          Application.put_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus, config)
      end
    end)
  end

  defp owner_output_state(task_pid, request_id, epoch \\ 1) when is_pid(task_pid) do
    downstream = %{pid: self(), epoch: epoch, correlation_id: "correlation-#{request_id}"}

    %{
      opts: %{request_id: request_id},
      tasks: MapSet.new([task_pid]),
      task_monitors: %{},
      queued_response_payloads: :queue.new(),
      native_turn_output_task_pids: MapSet.new(),
      websocket_owner_downstream: downstream,
      websocket_owner_drain_observed?: false,
      websocket_owner_active_turn_reconnect?: false,
      connection_started_at_monotonic_ms: System.monotonic_time(:millisecond)
    }
  end

  defp public_owner_output_state(task_pid, request_id) when is_pid(task_pid) do
    task_pid
    |> owner_output_state(request_id)
    |> Map.put(:opts, public_owner_request_options(request_id))
    |> Map.put(:public_response_task_pid, task_pid)
    |> Map.put(
      :public_responses_websocket_state,
      Adapter.public_responses_turn_state()
    )
    |> Map.put(:public_turn_task_done?, false)
    |> Map.put(:public_turn_owner_complete?, false)
    |> Map.put(:public_turn_aborted?, false)
    |> Map.put(:public_turn_output_committed?, false)
  end

  defp public_owner_request_options(request_id) do
    %{request_id: request_id}
    |> RequestOptions.for_websocket()
    |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
  end

  defp replace_owner_output_task(state, previous_task_pid, next_task_pid) do
    state
    |> Map.put(:tasks, MapSet.new([next_task_pid]))
    |> Map.put(:task_monitors, %{})
    |> Map.update!(:native_turn_output_task_pids, &MapSet.delete(&1, previous_task_pid))
  end

  defp owner_frame(downstream, payload) do
    {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, payload}
  end

  defp public_owner_frame(downstream, owner_turn_id, payload) do
    {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, owner_turn_id, payload}
  end

  defp owner_error_payload(reason) do
    assert {:ok, payload} =
             WebsocketOwnerContract.safe_error_payload(reason, nil)

    {:error, reason, payload}
  end

  defp assert_native_owner_turn_log!(logs, request_id, visible_output) do
    assert length(Regex.scan(~r/websocket native turn failed/, logs)) == 1
    assert logs =~ "request_id=#{request_id}"
    assert logs =~ "visible_output=#{visible_output}"
    refute logs =~ "phase=receive"
  end

  defp socket_test_task do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_socket_test_task(task_pid) when is_pid(task_pid) do
    if Process.alive?(task_pid), do: send(task_pid, :stop)
  end

  defp owner_lifecycle_request_options(request_id, turn_state, extra_opts \\ []) do
    %{
      request_id: request_id,
      accepted_turn_state: turn_state,
      client_ip: "127.0.0.1"
    }
    |> Map.merge(Map.new(extra_opts))
    |> RequestOptions.for_websocket()
  end

  defp enable_request_compression!(pool) do
    pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      request_compression_enabled: true,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp supported_compression_model_opts do
    [
      exposed_model_id: @supported_compression_model,
      upstream_model_id: @supported_compression_model,
      pricing_ref: @supported_compression_model
    ]
  end

  defp refute_payload_compression_leak!(metadata, forbidden_values) when is_map(metadata) do
    metadata_text = inspect(metadata)

    for value <- forbidden_values do
      if String.contains?(metadata_text, value) do
        flunk("payload compression metadata leaked forbidden owner websocket request content")
      end
    end
  end

  defp receive_owner_socket_push(state) do
    receive do
      {:websocket_owner_cleanup_witness, _, _, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:codex_response_done, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_owner_socket_push_message(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected owner websocket response frame")
    end
  end

  defp receive_native_collect_socket_push(state) do
    receive do
      {:websocket_owner_cleanup_witness, _, _, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:codex_response_chunk, _task_pid, _frame} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:codex_response_done, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected collected native websocket response frame")
    end
  end

  defp handle_native_collect_socket_push_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:push, {:text, frame}, state} = result ->
        if StreamProtocol.internal_control_event?(frame) do
          receive_native_collect_socket_push(state)
        else
          result
        end

      {:ok, state} ->
        receive_native_collect_socket_push(state)
    end
  end

  defp handle_owner_socket_push_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:push, {:text, frame}, state} = result ->
        if StreamProtocol.internal_control_event?(frame) do
          receive_owner_socket_push(state)
        else
          result
        end

      {:ok, state} ->
        receive_owner_socket_push(state)
    end
  end

  defp receive_owner_socket_raw_push(state) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:codex_response_done, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected owner websocket response frame")
    end
  end

  defp handle_owner_socket_raw_push_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:push, {:text, _frame}, _state} = result -> result
      {:ok, state} -> receive_owner_socket_raw_push(state)
    end
  end

  defp receive_owner_socket_complete(state) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
        handle_owner_socket_complete_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        handle_owner_socket_complete_message(message, state)

      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
        handle_owner_socket_complete_control(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_owner_socket_complete_control(message, state)

      {:codex_response_done, _, _} = message ->
        handle_owner_socket_complete_control(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_owner_socket_complete_control(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected owner websocket completion frame")
    end
  end

  defp handle_owner_socket_complete_message(message, state) do
    accepted_completion? =
      Adapter.accept_downstream_message(message, state) == {:ok, :complete}

    result = CodexResponsesSocket.handle_info(message, state)

    case result do
      {:ok, next_state} ->
        if accepted_completion? or owner_completion_transition?(message, state, next_state) do
          {:ok, next_state}
        else
          receive_owner_socket_complete(next_state)
        end

      {:push, _frame, state} ->
        receive_owner_socket_complete(state)

      {:stop, _reason, _detail, _state} = stop ->
        stop

      {:stop, _reason, _detail, _frames, _state} = stop ->
        stop
    end
  end

  defp owner_completion_transition?(
         {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, :complete},
         previous_state,
         next_state
       ) do
    owner_completion_state_transition?(previous_state, next_state)
  end

  defp owner_completion_transition?(
         {:websocket_owner_frame, _correlation_id, _epoch, :complete},
         previous_state,
         next_state
       ) do
    owner_completion_state_transition?(previous_state, next_state)
  end

  defp owner_completion_transition?(_message, _previous_state, _next_state), do: false

  defp owner_completion_state_transition?(previous_state, next_state) do
    (not Map.get(previous_state, :native_owner_terminal_delivered?, false) and
       Map.get(next_state, :native_owner_terminal_delivered?, false)) or
      (not Map.get(previous_state, :public_turn_owner_complete?, false) and
         Map.get(next_state, :public_turn_owner_complete?, false)) or
      (Map.get(previous_state, :websocket_owner_active_turn_reconnect?, false) and
         not Map.get(next_state, :websocket_owner_active_turn_reconnect?, false))
  end

  defp handle_owner_socket_complete_control(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:ok, state} -> receive_owner_socket_complete(state)
      {:push, _frame, state} -> receive_owner_socket_complete(state)
      {:stop, _reason, _detail, _state} = stop -> stop
      {:stop, _reason, _detail, _frames, _state} = stop -> stop
    end
  end

  defp flush_socket_done(state) do
    receive do
      {:codex_response_done, pid, result} ->
        CodexResponsesSocket.handle_info({:codex_response_done, pid, result}, state)
    after
      100 -> :ok
    end
  end

  defp request_logs(pool_id) do
    Repo.all(
      from(r in Request,
        where: r.pool_id == ^pool_id,
        order_by: [asc: r.admitted_at]
      )
    )
  end

  defp assert_native_turn_correlation!(correlation_id) when is_binary(correlation_id) do
    assert correlation_id =~ ~r/\Acodex-turn:[A-Za-z0-9_-]{43}\z/
  end

  defp assert_native_request_correlation!(correlation_id) when is_binary(correlation_id) do
    assert correlation_id =~ ~r/\Acodex-request:[A-Za-z0-9_-]{43}\z/
  end

  defp event_count(log, message) when is_binary(log) and is_binary(message) do
    log
    |> String.split(message)
    |> length()
    |> Kernel.-(1)
  end

  defp capture_stream_outcome_telemetry(fun) do
    handler_id = "owner-stream-outcome-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_outcome, metadata})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp attach_stream_outcome_telemetry! do
    handler_id = "owner-residency-stream-outcome-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_outcome, metadata})
        end,
        nil
      )

    handler_id
  end

  defp assert_websocket_lifecycle_line!(logs, message, required_keys, optional_keys) do
    lifecycle_lines =
      logs
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, message))

    assert [line] = lifecycle_lines

    metadata_text =
      line
      |> String.replace_prefix(message, "")
      |> String.trim_leading()

    metadata_keys =
      metadata_text
      |> String.split(" ", trim: true)
      |> Enum.map(fn token -> token |> String.split("=", parts: 2) |> hd() end)

    assert Enum.all?(metadata_keys, &(&1 in @websocket_lifecycle_metadata_keys))
    assert Enum.all?(required_keys, &(&1 in metadata_keys))
    assert Enum.all?(metadata_keys, &(&1 in (required_keys ++ optional_keys)))
    assert_no_websocket_lifecycle_leaks!(logs)

    line
  end

  defp assert_no_websocket_lifecycle_leaks!(logs) do
    downcased_logs = String.downcase(logs)

    for forbidden_term <- @websocket_lifecycle_forbidden_terms do
      refute downcased_logs =~ forbidden_term
    end

    refute downcased_logs =~ @sentinel
  end

  defp assert_abnormal_owner_monitor_down_crashes_active_turn!(owner_reason, suffix) do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_#{suffix}"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-#{suffix}",
          accepted_turn_state: "stable-ws-owner-monitor-#{suffix}",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(owner_reason)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, monitored_state) end)

    assert {:stop, :normal, {1011, "websocket owner crashed"}, stopped_state} =
             handle_result

    refute Map.has_key?(stopped_state, :websocket_owner_monitor)
    refute Map.has_key?(stopped_state, :websocket_owner_pid)
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "owner_drained"
    refute logs =~ "client_disconnected"
    assert_no_leak!("owner #{suffix} abnormal monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_crashed"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_crashed"

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(stopped_state, :websocket_owner_downstream)
    )
  end

  defp assert_graceful_owner_monitor_down_drains_active_turn!(owner_reason, suffix) do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_owner_#{suffix}"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-owner-monitor-#{suffix}",
          accepted_turn_state: "stable-ws-owner-monitor-#{suffix}",
          client_ip: "127.0.0.1"
        }
      })

    %{request: request, attempt: attempt, turn: turn, state: state} =
      active_socket_turn_fixture(setup, upstream, state)

    {owner_pid, owner_monitor, owner_down} = owner_monitor_down(owner_reason)

    monitored_state = %{
      state
      | websocket_owner_pid: owner_pid,
        websocket_owner_monitor: owner_monitor
    }

    {handle_result, logs} =
      with_log(fn -> CodexResponsesSocket.handle_info(owner_down, monitored_state) end)

    assert {:ok, kept_state} = handle_result
    refute Map.has_key?(kept_state, :websocket_owner_monitor)
    refute Map.has_key?(kept_state, :websocket_owner_pid)
    refute logs =~ "owner_crashed"
    refute logs =~ "owner_unavailable_takeover"
    refute logs =~ "client_disconnected"
    assert_no_leak!("owner #{suffix} monitor logs", logs)

    assert_owner_interruption_state!(%{
      request: request,
      attempt: attempt,
      turn: turn,
      session: state.codex_session,
      error_code: "owner_drained"
    })

    assert released_owner_lease(
             state.codex_session.id,
             state.codex_session.owner_lease_token
           ).metadata["release_reason"] == "owner_drained"

    CodexResponsesSocket.terminate(
      :closed,
      Map.delete(kept_state, :websocket_owner_downstream)
    )
  end

  defp owner_monitor_down(owner_reason) do
    owner_pid =
      spawn(fn ->
        receive do
          {:finish_owner, :normal} -> :ok
          {:finish_owner, reason} -> exit(reason)
        end
      end)

    owner_monitor = Process.monitor(owner_pid)
    send(owner_pid, {:finish_owner, owner_reason})
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, ^owner_reason} = owner_down
    {owner_pid, owner_monitor, owner_down}
  end

  test "missing cleanup witness for an accepted owner task remains observable and preserves work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "owner-missing-witness", "owner-missing-witness")
    %{state: state, request: request} = active_socket_turn_fixture(setup, upstream, state)
    release_task = suspend_cleanup_task!(state)

    incomplete =
      state
      |> Map.delete(:websocket_owner_cleanup_witness)
      |> Map.delete(:websocket_owner_cleanup_task)

    {_result, logs} =
      with_log(fn ->
        Adapter.handle_monitor_down(incomplete, state.websocket_owner_pid, :shutdown)
      end)

    assert logs =~ "failure_reason=stale_owner_cleanup"
    assert Repo.reload!(request).status == "in_progress"

    assert active_owner_lease(state.codex_session.id).lease_token ==
             state.websocket_owner_lease_token

    assert Process.alive?(state.websocket_owner_pid)
    release_task.()
    CodexResponsesSocket.terminate(:closed, state)
  end

  defp suspend_cleanup_task!(state) do
    task = state.websocket_owner_cleanup_task
    test_process = self()
    barrier = make_ref()

    holder =
      spawn(fn ->
        monitor = Process.monitor(test_process)
        true = :erlang.suspend_process(task)
        send(test_process, {:cleanup_task_suspended, barrier})

        receive do
          {:release_cleanup_task, ^barrier} -> :ok
          {:DOWN, ^monitor, :process, ^test_process, _reason} -> :ok
        end
      end)

    assert_receive {:cleanup_task_suspended, ^barrier}, @handoff_detection_timeout_ms
    on_exit(fn -> send(holder, {:release_cleanup_task, barrier}) end)

    fn ->
      monitor = Process.monitor(holder)
      send(holder, {:release_cleanup_task, barrier})
      assert_receive {:DOWN, ^monitor, :process, ^holder, _reason}, @handoff_detection_timeout_ms
    end
  end

  defp active_socket_turn_fixture(setup, upstream, state) do
    release_ref = make_ref()

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.delayed_terminal_sse_stream(
        [],
        %{"type" => "response.completed", "response" => %{"status" => "completed"}},
        notify: self(),
        release_ref: release_ref
      )
    )

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {websocket_payload(setup, "owner lifecycle"), [opcode: :text]},
               state
             )

    assert_receive {:websocket_owner_cleanup_witness, _correlation, _epoch, _task, witness} =
                     message,
                   @handoff_detection_timeout_ms

    assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
    assert state.websocket_owner_cleanup_witness == witness

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, barrier, ^release_ref},
                   @handoff_detection_timeout_ms

    on_exit(fn -> send(barrier, {:fake_upstream_release_timeout, release_ref}) end)
    request = Repo.get!(Request, witness.request_id)
    attempt = Repo.get!(Attempt, witness.attempt_id)
    turn = Repo.get_by!(CodexTurn, request_id: request.id)
    assert request.status == "in_progress"
    assert attempt.status == "in_progress"
    assert turn.status == "in_progress"
    %{request: request, attempt: attempt, turn: turn, state: state}
  end

  defp accept_fixture_owner_request!(owner, session, request, attempt, block_ref) do
    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: self(),
               correlation_id: Ecto.UUID.generate()
             })

    request
    |> Ecto.Changeset.change(
      request_metadata: %{
        "codex_session_id" => session.id,
        "websocket_owner_forwarding" => %{
          "owner_instance_id" => session.owner_instance_id,
          "downstream_epoch" => downstream.epoch
        }
      }
    )
    |> Repo.update!()

    submission = %UpstreamWebsocketSession.Request{
      request_id: request.id,
      attempt_id: attempt.id,
      url: "http://127.0.0.1/unused",
      headers: [],
      payload: "{}"
    }

    caller = self()

    submitter =
      spawn(fn ->
        result = WebsocketOwnerSession.submit_request(owner, downstream, submission)
        send(caller, {:fixture_owner_submission_finished, self(), result})
      end)

    monitor = Process.monitor(submitter)

    on_exit(fn ->
      if Process.alive?(submitter), do: Process.exit(submitter, :shutdown)
    end)

    assert_receive {:websocket_owner_harness_barrier, _worker, ^block_ref},
                   @handoff_detection_timeout_ms

    assert_receive {:websocket_owner_cleanup_witness, _correlation, _epoch, _task, witness},
                   @handoff_detection_timeout_ms

    assert witness.request_id == request.id
    assert witness.attempt_id == attempt.id
    {submitter, monitor}
  end

  defp active_turn_fixture(setup, auth, session, transport \\ "websocket") do
    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => "owner lifecycle"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: transport,
                 correlation_id: "ws-owner-lifecycle-#{System.unique_integer([:positive])}",
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)
    %{request: reserved.request, attempt: attempt, turn: turn}
  end

  defp assert_owner_interruption_state!(%{
         request: request,
         attempt: attempt,
         turn: turn,
         session: session,
         error_code: error_code
       }) do
    reloaded_request = Repo.get!(Request, request.id)
    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    reloaded_turn = Repo.get!(CodexTurn, turn.id)
    reloaded_session = Repo.get!(CodexSession, session.id)

    assert reloaded_request.status == "failed"
    assert reloaded_request.response_status_code == 499
    assert reloaded_request.last_error_code == error_code
    assert reloaded_attempt.status == "failed"
    assert reloaded_attempt.upstream_status_code == 499
    assert reloaded_attempt.network_error_code == error_code
    assert reloaded_turn.status == "interrupted"
    assert reloaded_turn.error_code == error_code
    assert reloaded_turn.final_attempt_id == attempt.id
    assert reloaded_session.status == "interrupted"
  end

  defp assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn}) do
    reloaded_request = Repo.get!(Request, request.id)
    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    reloaded_turn = Repo.get!(CodexTurn, turn.id)

    assert reloaded_request.status == "succeeded"
    assert reloaded_request.response_status_code == 200
    assert is_nil(reloaded_request.last_error_code)
    assert reloaded_attempt.status == "succeeded"
    assert reloaded_attempt.upstream_status_code == 200
    assert is_nil(reloaded_attempt.network_error_code)
    assert reloaded_turn.status == "succeeded"
    assert is_nil(reloaded_turn.error_code)
    assert reloaded_turn.final_attempt_id == attempt.id
  end

  defp assert_no_leak_in_persistence!(pool_id) do
    assert_no_leak!("persistence rows", persistence_excerpt(pool_id))
  end

  defp synthetic_access_token(residency) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)

    payload =
      Base.url_encode64(
        Jason.encode!(%{
          "https://api.openai.com/auth" => %{
            "chatgpt_compute_residency" => residency
          }
        }),
        padding: false
      )

    "#{header}.#{payload}.signature"
  end

  defp header_values(headers, target_name) do
    for {name, value} <- headers, String.downcase(name) == target_name, do: value
  end

  defp assert_owner_websocket_values_not_persisted!(setup, forbidden_values, logs) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    request_ids = Enum.map(requests, & &1.id)
    attempts = Repo.all(from(a in Attempt, where: a.request_id in ^request_ids))
    sessions = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    session_ids = Enum.map(sessions, & &1.id)
    turns = Repo.all(from(t in CodexTurn, where: t.codex_session_id in ^session_ids))
    audit_events = Repo.all(from(e in AuditEvent))
    request_logs = RequestLogs.list(setup.pool.id, limit: 10)

    durable_text =
      inspect({requests, attempts, sessions, turns, audit_events, request_logs.items})

    for value <- forbidden_values do
      refute durable_text =~ value
      refute logs =~ value
    end
  end

  defp refute_raw_turn_state_session_key!(pool_id, turn_state) do
    refute Repo.exists?(
             from session in CodexSession,
               where:
                 session.pool_id == ^pool_id and
                   fragment("lower(?)", session.session_key) == ^String.downcase(turn_state)
           )
  end

  defp turn_state_session_key(turn_state) do
    "x-codex-turn-state:" <>
      (:crypto.hash(:sha256, String.trim(turn_state)) |> Base.encode16(case: :lower))
  end

  defp persistence_excerpt(pool_id) do
    requests =
      Repo.all(
        from r in Request,
          where: r.pool_id == ^pool_id,
          order_by: [asc: r.admitted_at],
          select: %{
            endpoint: r.endpoint,
            transport: r.transport,
            status: r.status,
            request_metadata: r.request_metadata,
            last_error_code: r.last_error_code,
            response_status_code: r.response_status_code
          }
      )

    request_ids = Repo.all(from r in Request, where: r.pool_id == ^pool_id, select: r.id)
    session_ids = Repo.all(from s in CodexSession, where: s.pool_id == ^pool_id, select: s.id)

    %{
      requests: requests,
      attempts:
        Repo.all(
          from a in Attempt,
            where: a.request_id in ^request_ids,
            order_by: [asc: a.attempt_number],
            select: %{
              transport: a.transport,
              status: a.status,
              network_error_code: a.network_error_code,
              error_message: a.error_message,
              response_metadata: a.response_metadata
            }
        ),
      codex_sessions:
        Repo.all(
          from s in CodexSession,
            where: s.pool_id == ^pool_id,
            select: %{
              session_key: s.session_key,
              conversation_key: s.conversation_key,
              status: s.status,
              owner_instance_id: s.owner_instance_id
            }
        ),
      codex_turns:
        Repo.all(
          from t in CodexTurn,
            where: t.codex_session_id in ^session_ids,
            select: %{
              transport_kind: t.transport_kind,
              status: t.status,
              error_code: t.error_code
            }
        ),
      bridge_owner_leases:
        Repo.all(
          from l in BridgeOwnerLease,
            where: l.pool_id == ^pool_id,
            select: %{
              owner_instance_id: l.owner_instance_id,
              status: l.status,
              metadata: l.metadata
            }
        ),
      bridge_session_aliases:
        Repo.all(
          from a in BridgeSessionAlias,
            where: a.pool_id == ^pool_id,
            select: %{
              alias_kind: a.alias_kind,
              alias_preview: a.alias_preview,
              status: a.status,
              metadata: a.metadata
            }
        )
    }
  end

  defp assert_leak_allowed_only_in_fake_upstream!(request) do
    assert inspect(%{body: request.body, json: request.json}) =~ @sentinel
    assert_no_leak!("fake upstream metadata", Map.drop(request, [:body, :json]))
  end

  defp assert_no_leak!(label, value) do
    if value |> inspect(limit: 80, printable_limit: 4_000) |> String.contains?(@sentinel) do
      flunk("sentinel leaked through #{label}")
    end
  end

  defp assert_sensitive_tracked_response_task!(state) do
    [pid] = MapSet.to_list(state.tasks)
    assert_sensitive_process_hides_mailbox!(pid)
  end

  defp assert_sensitive_process_hides_mailbox!(pid) when is_pid(pid) do
    marker = {:sensitive_probe, make_ref(), @sentinel}
    send(pid, marker)
    assert_process_messages_hidden!(pid, 100)
  end

  defp assert_process_messages_hidden!(pid, attempts) when attempts > 0 do
    case :erlang.process_info(pid, :messages) do
      {:messages, []} ->
        :ok

      nil ->
        flunk("sensitive process exited before introspection check")

      _messages ->
        yield_once({:assert_process_messages_hidden, pid, attempts})
        assert_process_messages_hidden!(pid, attempts - 1)
    end
  end

  defp assert_process_messages_hidden!(_pid, 0), do: flunk("sensitive process exposed mailbox")

  defp assert_stale_owner_downstream_ignored(owner_pid, stale_downstream, state) do
    stale_payload = Jason.encode!(%{"id" => "resp_owner_retarget_stale_origin_frame"})

    stale_message =
      {:websocket_owner_frame, stale_downstream.correlation_id, stale_downstream.epoch,
       {:data, stale_payload}}

    case WebsocketOwnerSession.push_downstream(owner_pid, {:data, stale_payload}) do
      :ok ->
        assert_receive ^stale_message

      {:error, reason} ->
        assert reason in [:duplicate_downstream, :owner_unavailable, :stale_downstream]
    end

    case CodexResponsesSocket.handle_info(stale_message, state) do
      {:ok, state} ->
        state

      {:push, _frame, _state} ->
        flunk("stale origin downstream frame was accepted after retarget")
    end
  end

  defp downstream_target(correlation_id),
    do: %{pid: self(), epoch: 1, correlation_id: correlation_id}

  defp crashing_owner_upstream_boundary(test_pid) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false} end) end,
      send: fn upstream_pid, _payload, _writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:crashing_owner_upstream_received, upstream_pid})
        exit(:simulated_owner_worker_crash)
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp chained_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{count: 0} end) end,
      send: fn upstream_pid, upstream_payload, writer ->
        count =
          Agent.get_and_update(upstream_pid, fn state ->
            {state.count + 1, %{state | count: state.count + 1}}
          end)

        case {count, upstream_payload} do
          {1, %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{}} ->
            frame = Jason.encode!(%{"id" => "resp_owner_queue_first", "object" => "response"})
            writer.(frame, TerminalDiscriminator.classify(frame))
            :ok

          {2, payload} when is_binary(payload) ->
            send(test_pid, {:chained_owner_upstream_processed_blocked, self(), release_ref})

            receive do
              {:chained_owner_upstream_release, ^release_ref} -> :ok
            after
              5_000 -> exit(:chained_owner_upstream_timeout)
            end

          {3, %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{}} ->
            send(test_pid, {:chained_owner_upstream_tool_started, release_ref})
            frame = Jason.encode!(%{"id" => "resp_owner_queue_tool", "object" => "response"})
            writer.(frame, TerminalDiscriminator.classify(frame))
            :ok
        end
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false, closed?: false} end) end,
      send: fn upstream_pid, _request, _writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:blocking_owner_upstream_received, self(), release_ref})

        receive do
          {:blocking_owner_upstream_release, ^release_ref} -> :ok
        after
          5_000 -> exit(:blocking_owner_upstream_timeout)
        end
      end,
      close: fn upstream_pid ->
        Agent.update(upstream_pid, fn state -> %{state | closed?: true} end)
        Agent.stop(upstream_pid)
      end
    }
  end

  defp terminal_blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false, closed?: false} end) end,
      send: fn upstream_pid, request, writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:blocking_owner_upstream_received, self(), release_ref})

        receive do
          {:blocking_owner_upstream_release, ^release_ref} ->
            frame =
              Jason.encode!(%{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_owner_active_reconnect",
                  "status" => "completed",
                  "output" => [],
                  "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
                }
              })

            decoded = Jason.decode!(frame)

            cond do
              is_function(request.frame_observer, 2) -> request.frame_observer.(frame, decoded)
              is_function(request.frame_observer, 1) -> request.frame_observer.(frame)
              true -> :ok
            end

            writer.(frame, TerminalDiscriminator.classify(frame))
            :ok
        after
          5_000 -> exit(:blocking_owner_upstream_timeout)
        end
      end,
      close: fn upstream_pid ->
        Agent.update(upstream_pid, fn state -> %{state | closed?: true} end)
        Agent.stop(upstream_pid)
      end
    }
  end

  defp reconnect_handoff_owner_upstream_boundary(test_pid) do
    counter = :counters.new(1, [:atomics])

    %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        :ok = :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        if count == 1 do
          Process.flag(:trap_exit, true)
          send(test_pid, {:controller_handoff_predecessor_started, self()})

          receive do
            {:EXIT, _from, :shutdown} ->
              receive do
                :controller_handoff_never -> :ok
              end
          end
        else
          send(test_pid, {:controller_handoff_replacement_started, count})
          :ok
        end
      end,
      invalidate: fn _upstream_pid -> :ok end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp visible_blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, request, writer ->
        frame =
          Jason.encode!(%{"id" => "resp_owner_visible_before_crash", "object" => "response"})

        decoded = Jason.decode!(frame)

        cond do
          is_function(request.frame_observer, 2) -> request.frame_observer.(frame, decoded)
          is_function(request.frame_observer, 1) -> request.frame_observer.(frame)
          true -> :ok
        end

        writer.(frame, TerminalDiscriminator.classify(frame))
        send(test_pid, {:visible_blocking_owner_upstream, self(), release_ref})

        receive do
          {:visible_blocking_owner_release, ^release_ref} -> :ok
        after
          5_000 -> exit(:visible_blocking_owner_timeout)
        end
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end

  defp frame_observer_failure_upstream_boundary(test_pid, marker) do
    %{
      start: fn -> UpstreamWebsocketSession.start_link([]) end,
      send: fn upstream_pid, request, writer ->
        original_observer = request.frame_observer

        observer = fn frame, decoded ->
          send(test_pid, {:owner_frame_observer_failed, self()})
          invoke_frame_observer(original_observer, frame, decoded)
          raise marker
        end

        request = %{request | writer: writer, frame_observer: observer}
        UpstreamWebsocketSession.request(upstream_pid, request)
      end,
      close: &UpstreamWebsocketSession.close/1
    }
  end

  defp invoke_frame_observer(observer, frame, decoded) when is_function(observer, 2),
    do: observer.(frame, decoded)

  defp invoke_frame_observer(observer, frame, _decoded) when is_function(observer, 1),
    do: observer.(frame)

  defp invoke_frame_observer(_observer, _frame, _decoded), do: :ok

  defp assert_blocking_owner_upstream_received!(release_ref) do
    receive do
      {:blocking_owner_upstream_received, owner_worker_pid, ^release_ref} -> owner_worker_pid
    after
      @blocking_owner_receive_timeout_ms ->
        flunk("expected blocking owner upstream to receive the websocket request")
    end
  end

  defp assert_response_task_stopped!(state) do
    [response_task_pid] = MapSet.to_list(state.tasks)
    assert_response_task_stopped!(state, response_task_pid)
  end

  defp assert_response_task_stopped!(_state, response_task_pid) do
    monitor = Process.monitor(response_task_pid)

    assert_receive {:DOWN, ^monitor, :process, ^response_task_pid, _reason},
                   @response_task_stop_timeout_ms
  end

  defp acknowledge_response_task_delivery_if_pending(state, task_pid) do
    case Map.fetch(state.response_task_activities, task_pid) do
      {:ok, token} ->
        CodexResponsesSocket.handle_info(
          {:websocket_response_delivery_complete, task_pid, token},
          state
        )

      :error ->
        if MapSet.member?(state.tasks, task_pid) do
          receive do
            {:websocket_response_activity, ^task_pid, _token} = message ->
              assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
              acknowledge_response_task_delivery_if_pending(state, task_pid)
          after
            @response_task_stop_timeout_ms ->
              flunk("expected response task activity registration")
          end
        else
          {:ok, state}
        end
    end
  end

  defp crashing_owner_safe_state(upstream_pid) do
    Agent.get(upstream_pid, fn state -> state end)
  catch
    :exit, _reason -> %{closed?: true}
  end

  defp active_owner_lease(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1
    )
  end

  defp released_owner_lease(session_id, lease_token) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^session_id and lease.lease_token == ^lease_token and
            lease.status == "released",
        limit: 1
    )
  end

  defp released_owner_lease_optional(session_id, lease_token) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^session_id and lease.lease_token == ^lease_token and
            lease.status == "released",
        limit: 1
    )
  end

  defp await_upstream_requests(upstream, expected_count, attempts \\ 100)

  defp await_upstream_requests(upstream, expected_count, attempts) when attempts > 0 do
    requests = FakeUpstream.requests(upstream)

    if length(requests) == expected_count do
      requests
    else
      yield_once({:await_upstream_requests, expected_count, attempts})
      await_upstream_requests(upstream, expected_count, attempts - 1)
    end
  end

  defp await_upstream_requests(upstream, _expected_count, 0), do: FakeUpstream.requests(upstream)

  defp yield_once(message) do
    send(self(), message)

    receive do
      ^message -> :ok
    end
  end

  defp with_single_proxy_websocket_slot(fun) do
    with_proxy_websocket_bulkhead(0, 1_000, fun)
  end

  defp with_proxy_websocket_bulkhead(queue_limit, queue_timeout_ms, fun)
       when is_integer(queue_limit) and queue_limit >= 0 and is_integer(queue_timeout_ms) and
              queue_timeout_ms > 0 and is_function(fun, 0) do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        bulkheads:
          Map.new(Admission.route_classes(), fn route_class ->
            {route_class, %{max_concurrency: 4, queue_limit: 0, queue_timeout_ms: 1_000}}
          end)
          |> Map.put("proxy_websocket", %{
            max_concurrency: 1,
            queue_limit: queue_limit,
            queue_timeout_ms: queue_timeout_ms
          })
      }
    )

    Admission.reset_for_test()

    try do
      fun.()
    after
      Admission.reset_for_test()

      case previous_settings do
        nil -> Application.delete_env(:codex_pooler, OperationalSettings)
        value -> Application.put_env(:codex_pooler, OperationalSettings, value)
      end
    end
  end

  defp cleanup_local_owner_sessions do
    logs =
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn codex_session_id ->
          await_owner_cleanup!(codex_session_id)
        end)
      end)

    assert_no_leak!("owner cleanup logs", logs)
  end

  defp await_owner_cleanup!(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner_pid} ->
        monitor = Process.monitor(owner_pid)

        try do
          GenServer.stop(owner_pid, :shutdown, @handoff_detection_timeout_ms)
        catch
          :exit, {:noproc, _details} -> :ok
          :exit, {:normal, _details} -> :ok
        end

        assert_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason},
                       @handoff_detection_timeout_ms

      {:error, :owner_unavailable} ->
        :ok
    end

    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(codex_session_id)
  end
end
