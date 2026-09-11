defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.ContinuationTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient
  alias CodexPoolerWeb.WebsocketConnectionLogger

  @supported_compression_model "gpt-4o"
  @queued_owner_upstream_start_timeout_ms 5_000
  @handoff_detection_timeout_ms 15_000

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

  @tag :continuation_generation_boundary
  @tag :replay_topology
  test "direct owner guards a replacement generation and settles once before full retry" do
    assert_owner_continuation_generation_boundary(:direct)
  end

  @tag :continuation_generation_boundary
  @tag :replay_topology
  test "proxy-to-owner guards a replacement generation and settles once before full retry" do
    assert_owner_continuation_generation_boundary(:proxy)
  end

  @tag :findings116
  test "direct owner retires a connection-limit socket before guarded recovery" do
    assert_owner_connection_limit_recovery(:direct)
  end

  @tag :findings116
  test "proxy-to-owner retires a connection-limit socket before guarded recovery" do
    assert_owner_connection_limit_recovery(:proxy)
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
    assert %{"id" => "resp_owner_processed"} = CodexPooler.JSON.decode!(first_frame)
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
        CodexPooler.JSON.encode!(%{
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

  test "tool-output continuation after reconnect is forwarded through the owner" do
    upstream =
      start_upstream(
        # Strict finite scenario: both turns must reach the owner's single
        # upstream connection, the continuation must carry the anchor, and no
        # third send may occur across the downstream reconnect.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_tool_first",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_tool_first"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_tool_second",
                  "object" => "response"
                })
              ])
          )
        ])
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

    assert {:push, {:text, first_frame}, first_state} = receive_owner_socket_push(first_state)
    assert [first_request] = FakeUpstream.requests(upstream)
    refute Map.has_key?(first_request.json, "previous_response_id")

    assert %{"id" => "resp_owner_tool_first"} = CodexPooler.JSON.decode!(first_frame)
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
      schema_bound_output =
        CodexPooler.JSON.encode!(%{"rows" => Enum.to_list(1..160)}, pretty: true)

      unbound_output = CodexPooler.JSON.encode!(%{"rows" => Enum.to_list(161..320)}, pretty: true)

      assert byte_size(schema_bound_output) > 512
      assert byte_size(unbound_output) > 512

      tool_payload =
        CodexPooler.JSON.encode!(%{
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

      assert {:push, {:text, second_frame}, second_state} =
               receive_owner_socket_push(second_state)

      assert [^first_request, second_request] = FakeUpstream.requests(upstream)
      assert second_request.json["previous_response_id"] == "resp_owner_tool_first"

      assert %{"id" => "resp_owner_tool_second"} = CodexPooler.JSON.decode!(second_frame)
      assert {:ok, _second_state} = receive_socket_done(second_state)

      assert [^first_request, ^second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_owner_tool_first"
      assert :ok = FakeUpstream.verify!(upstream)

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

      assert CodexPooler.JSON.decode!(schema_bound_item["output"]) ==
               CodexPooler.JSON.decode!(schema_bound_output)

      assert unbound_item["output"] != unbound_output

      assert CodexPooler.JSON.decode!(unbound_item["output"]) ==
               CodexPooler.JSON.decode!(unbound_output)

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
        # Strict finite scenario: the first turn, the processed ack, and the
        # tool continuation are the only three sends, all on the owner's single
        # connection, and the continuation carries the first response id.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_chain_first",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.processed"}],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_chain_processed",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_chain_first",
                "input.0.type" => "function_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_chain_tool",
                  "object" => "response"
                })
              ])
          )
        ])
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
      assert %{"id" => "resp_owner_chain_first"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, processed_state} = owner_socket(auth, "ws-owner-chain-processed", turn_state)

    try do
      processed_payload =
        CodexPooler.JSON.encode!(%{
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
        CodexPooler.JSON.encode!(%{
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
      assert %{"id" => "resp_owner_chain_tool"} = CodexPooler.JSON.decode!(tool_frame)
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

    assert :ok = FakeUpstream.verify!(upstream)
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
      assert %{"id" => "resp_owner_queue_first"} = CodexPooler.JSON.decode!(first_frame)
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
        CodexPooler.JSON.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_owner_queue_first",
          "request_id" => "ws-owner-queue-processed"
        })

      tool_payload =
        CodexPooler.JSON.encode!(%{
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
      assert %{"id" => "resp_owner_queue_tool"} = CodexPooler.JSON.decode!(tool_frame)
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
        # Strict finite scenario: the two anchors open the two target owner
        # connections, the active turn runs through the blocking boundary and
        # never reaches this upstream, and each queued continuation is the only
        # other send on its own target's connection with its own anchor id.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_queue_alias_anchor_a",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_queue_alias_anchor_b",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_queue_alias_anchor_a"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_queue_alias_a",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_queue_alias_anchor_b"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_queue_alias_b",
                  "object" => "response"
                })
              ])
          )
        ])
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

        assert %{"id" => "resp_owner_queue_alias_anchor_a"} =
                 CodexPooler.JSON.decode!(anchor_a_frame)

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

        assert %{"id" => "resp_owner_queue_alias_anchor_b"} =
                 CodexPooler.JSON.decode!(anchor_b_frame)

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

        assert %{"id" => "resp_owner_queue_alias_a"} = CodexPooler.JSON.decode!(queued_a_frame)
        assert {:ok, queued_b_state} = receive_socket_done(queued_a_state)
        assert queued_b_state.codex_session.id == target_b_session.id
        refute queued_b_state.codex_session.id == target_a_session.id
        refute queued_b_state.codex_session.id == origin_session.id

        assert {:push, {:text, queued_b_frame}, queued_b_state} =
                 receive_owner_socket_push(queued_b_state)

        assert %{"id" => "resp_owner_queue_alias_b"} = CodexPooler.JSON.decode!(queued_b_frame)
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
    assert :ok = FakeUpstream.verify!(upstream)
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
      assert %{"id" => "resp_owner_queue_first"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, _first_state} = receive_socket_done(first_state)
    after
      CodexResponsesSocket.terminate(:closed, first_state)
    end

    {:ok, processed_state} = owner_socket(auth, "ws-owner-processed-close", turn_state)

    processed_payload =
      CodexPooler.JSON.encode!(%{
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

    assert CodexPooler.JSON.decode!(native_error)["error"]["code"] == "owner_busy"

    assert {:push, {:text, processed_error}, ^reconnect_state} =
             CodexResponsesSocket.handle_in(
               {processed_payload, [opcode: :text]},
               reconnect_state
             )

    assert CodexPooler.JSON.decode!(processed_error)["error"]["code"] == "owner_busy"
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
       {:data, CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta"})}},
      {:websocket_owner_output_commit_probe, "owner-helper-control", 41, task_pid,
       active_turn_ref, self(), probe_ref},
      {:websocket_response_activity, task_pid, token},
      {:codex_response_done, task_pid, :ok},
      {:websocket_owner_frame, "owner-helper-control", 41, task_pid,
       {:data, CodexPooler.JSON.encode!(%{"type" => "response.completed"})}},
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

    # Strict finite scenario: the three chained turns are the only sends, all on
    # the owner's single connection, each carrying its predecessor's response id.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence(
          response_ids
          |> Enum.with_index()
          |> Enum.map(fn {response_id, index} ->
            previous_expectation =
              case index do
                0 -> [forbidden: ["previous_response_id"]]
                _ -> []
              end

            equals =
              case index do
                0 ->
                  %{"type" => "response.create"}

                _ ->
                  %{
                    "type" => "response.create",
                    "previous_response_id" => Enum.at(response_ids, index - 1)
                  }
              end

            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: equals] ++ previous_expectation,
              respond:
                FakeUpstream.websocket_text_frames([
                  CodexPooler.JSON.encode!(%{"id" => response_id, "object" => "response"})
                ])
            )
          end)
        )
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
      assert :ok = FakeUpstream.verify!(upstream)
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

  defp receive_owner_forwarded_complete(:direct, state), do: receive_owner_socket_complete(state)

  defp receive_owner_forwarded_complete(:proxy, state),
    do: receive_owner_continuity_complete(:proxy, state)

  defp assert_owner_continuation_generation_boundary(route) do
    previous_response_id = "resp_owner_generation_anchor_#{route}"
    private_input = "synthetic private owner continuation #{route}"

    upstream =
      start_upstream(
        # Strict finite scenario: the anchor is the only send on the first
        # connection, the guarded continuation sends nothing after the
        # invalidation, and the explicit full retry is the only send on the
        # replacement connection.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{"id" => previous_response_id, "object" => "response"})
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_owner_generation_retry_#{route}",
                  "object" => "response"
                })
              ])
          )
        ])
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

      assert CodexPooler.JSON.decode!(retry_terminal) ==
               CodexPooler.JSON.decode!(native_owner_retry_terminal())

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
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp assert_owner_connection_limit_recovery(route) when route in [:direct, :proxy] do
    anchor = "resp_owner_limit_anchor_#{route}"
    recovered = "resp_owner_limit_recovered_#{route}"
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (response.failed envelope variants; #116 saw a type error terminal)
        FakeUpstream.strict_sequence([
          strict_owner_response(anchor, 1),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond:
              FakeUpstream.websocket_connection_limit_terminal_barrier(
                shape: :top_level,
                notify: self(),
                release_ref: release_ref
              )
          ),
          strict_owner_response(recovered, 2)
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "owner-limit-recovery-#{route}-#{System.unique_integer([:positive])}"
    {:ok, state} = owner_socket(auth, "ws-owner-limit-#{route}", turn_state)
    state = maybe_proxy_owner_state(state, route)

    try do
      anchor_payload =
        websocket_payload(setup, "owner limit anchor #{route}", %{
          "request_id" => "ws-owner-limit-anchor-#{route}"
        })

      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 anchor_payload,
                 owner_response_options(state, owner_node_opts(state, route)),
                 fn _frame -> :ok end
               )

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(anchor_frame) == anchor
      assert {:ok, state} = receive_owner_socket_complete(state)

      limit_payload =
        websocket_payload(setup, "owner limit terminal #{route}", %{
          "request_id" => "ws-owner-limit-terminal-#{route}"
        })

      limit_task =
        Task.async(fn ->
          Gateway.run_websocket_response(
            auth,
            limit_payload,
            owner_response_options(state, owner_node_opts(state, route)),
            fn _frame -> :ok end
          )
        end)

      assert_receive {:fake_upstream_websocket_barrier, :before_terminal, upstream_pid,
                      ^release_ref},
                     @handoff_detection_timeout_ms

      assert FakeUpstream.websocket_connection_alive?(upstream, 1)
      assert FakeUpstream.count(upstream) == 2
      send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
      assert :ok = Task.await(limit_task, @handoff_detection_timeout_ms)

      state =
        case route do
          :direct ->
            assert {:ok, state} = receive_owner_forwarded_complete(route, state)
            state

          :proxy ->
            {:ok, reconnected_state} =
              owner_socket(
                auth,
                "ws-owner-limit-#{route}-reconnected",
                turn_state
              )

            maybe_proxy_owner_state(reconnected_state, route)
        end

      refute FakeUpstream.websocket_connection_alive?(upstream, 1)

      stale_payload =
        websocket_payload(setup, "owner stale anchor #{route}", %{
          "request_id" => "ws-owner-limit-stale-#{route}",
          "previous_response_id" => anchor
        })

      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 stale_payload,
                 owner_response_options(state, owner_node_opts(state, route)),
                 fn _frame -> :ok end
               )

      assert {:push, {:text, stale_frame}, state} = receive_owner_socket_push(state)

      assert CodexPooler.JSON.decode!(stale_frame) ==
               CodexPooler.JSON.decode!(native_owner_retry_terminal())

      assert {:ok, state} = receive_owner_forwarded_complete(route, state)
      assert FakeUpstream.count(upstream) == 2
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      recovery_payload =
        websocket_payload(setup, "client authored full recovery #{route}", %{
          "request_id" => "ws-owner-limit-recovery-#{route}"
        })

      assert :ok =
               Gateway.run_websocket_response(
                 auth,
                 recovery_payload,
                 owner_response_options(state, owner_node_opts(state, route)),
                 fn _frame -> :ok end
               )

      assert {:push, {:text, recovery_frame}, state} = receive_owner_socket_push(state)
      assert owner_response_id(recovery_frame) == recovered
      assert {:ok, _state} = receive_owner_forwarded_complete(route, state)

      assert [anchor_send, limit_send, recovery_send] = FakeUpstream.requests(upstream)
      assert anchor_send.websocket_connection_id == limit_send.websocket_connection_id
      assert recovery_send.websocket_connection_id != limit_send.websocket_connection_id
      refute Map.has_key?(recovery_send.json, "previous_response_id")

      assert [anchor_request, limit_request, stale_request, recovery_request] =
               request_logs(setup.pool.id)

      assert anchor_request.status == "succeeded"
      assert limit_request.status == "failed"
      assert limit_request.last_error_code == "websocket_connection_limit_reached"
      assert stale_request.status == "failed"
      assert stale_request.last_error_code == "stream_incomplete"
      assert recovery_request.status == "succeeded"

      for request <- [anchor_request, limit_request, stale_request, recovery_request] do
        assert Repo.aggregate(
                 from(attempt in Attempt, where: attempt.request_id == ^request.id),
                 :count
               ) == 1

        assert Repo.aggregate(
                 from(entry in LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 ),
                 :count
               ) == 1
      end

      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp owner_node_opts(_state, :direct), do: []

  defp owner_node_opts(state, :proxy), do: state.opts.websocket_owner_forwarder_opts

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

  defp assert_native_request_correlation!(correlation_id) when is_binary(correlation_id) do
    assert correlation_id =~ ~r/\Acodex-request:[A-Za-z0-9_-]{43}\z/
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
            frame =
              CodexPooler.JSON.encode!(%{
                "id" => "resp_owner_queue_first",
                "object" => "response"
              })

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

            frame =
              CodexPooler.JSON.encode!(%{"id" => "resp_owner_queue_tool", "object" => "response"})

            writer.(frame, TerminalDiscriminator.classify(frame))
            :ok
        end
      end,
      close: fn upstream_pid -> Agent.stop(upstream_pid) end
    }
  end
end
