defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ResendTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    LedgerEntry,
    Request,
    RequestClientRetryLink
  }

  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, CodexTurn, RoutingCircuitState}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000
  @large_websocket_frame_timeout 5_000
  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000

  for progress <- [
        :visible_output,
        :token_usage,
        :scalar_usage,
        :string_usage,
        :list_usage,
        :inconsistent_usage,
        :mixed_usage
      ] do
    @tag progress: progress
    test "quota denial after #{progress} does not move accounts", %{progress: progress} do
      terminal = %{
        "type" => "response.failed",
        "response" => %{"status" => "failed", "error" => %{"code" => "usage_limit_reached"}}
      }

      frames =
        case progress do
          :visible_output ->
            [
              %{"type" => "response.output_text.delta", "delta" => "synthetic visible output"},
              terminal
            ]

          :token_usage ->
            [
              put_in(terminal, ["response", "usage"], %{
                "input_tokens" => 1,
                "output_tokens" => 1,
                "total_tokens" => 2
              })
            ]

          :mixed_usage ->
            [
              terminal
              |> put_in(["response", "usage"], %{
                "input_tokens" => 1,
                "output_tokens" => 1,
                "total_tokens" => 2
              })
              |> Map.put("usage", %{
                "input_tokens" => 0,
                "output_tokens" => 0,
                "total_tokens" => 0
              })
            ]

          malformed ->
            usage =
              case malformed do
                :scalar_usage ->
                  4

                :string_usage ->
                  "invalid"

                :list_usage ->
                  []

                :inconsistent_usage ->
                  %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 0}
              end

            [put_in(terminal, ["response", "usage"], usage)]
        end

      upstream =
        start_upstream(FakeUpstream.websocket_text_frames(Enum.map(frames, &CodexPooler.JSON.encode!/1)))

      fallback_upstream =
        start_upstream(completed_response_frames("resp_quota_must_not_replay", 3, 1))

      setup = gateway_setup(upstream)

      fallback =
        gateway_upstream(setup.pool, fallback_upstream, "upstream-token-quota-control", compact?: false)

      prime_routing_quota!(fallback.identity)
      model = put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

      request_id =
        seed_preferring_assignment(
          [setup.assignment.id, fallback.assignment.id],
          setup.assignment.id
        )

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert :ok =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(%{
                   "type" => "response.create",
                   "model" => model.exposed_model_id,
                   "input" => native_text_input("synthetic quota negative control"),
                   "stream" => true,
                   "generate" => true
                 }),
                 %{request_id: request_id},
                 fn frame -> send(self(), {:quota_control_frame, frame}) end
               )

      assert FakeUpstream.count(upstream) == 1
      assert FakeUpstream.count(fallback_upstream) == 0
      assert [attempt] = Repo.all(from(a in Attempt))
      assert attempt.status == "failed"
      refute attempt.response_metadata["quota_rejection_before_output"]
    end
  end

  test "established native websocket moves a quota-rejected full-history turn to another account" do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
    end)

    # provenance: observed 2026-09-20 native pre-visible quota refusal; identities and content synthetic
    rejection =
      FakeUpstream.websocket_text_frames([
        CodexPooler.JSON.encode!(%{
          "type" => "response.failed",
          "headers" => %{
            "x-codex-primary-used-percent" => "100",
            "x-codex-primary-window-minutes" => "10080"
          },
          "response" => %{"status" => "failed", "error" => %{"code" => "usage_limit_reached"}}
        })
      ])

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_native_request(1, completed_response_frames("resp_quota_anchor", 3, 1)),
          strict_native_request(1, rejection)
        ])
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_native_request(1, completed_response_frames("resp_quota_fallback", 3, 1)),
          strict_native_request(1, completed_response_frames("resp_quota_next", 3, 1))
        ])
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-quota-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)
    assert :ok = Events.subscribe_pool(setup.pool)
    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())

    {conn, _websocket} =
      Enum.reduce(1..3, {conn, websocket}, fn turn, {conn, websocket} ->
        if turn == 2 do
          put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
        end

        payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" =>
              [
                %{
                  "type" => "reasoning",
                  "encrypted_content" => "synthetic-reasoning",
                  "content" => nil,
                  "summary" => []
                }
              ] ++
                native_text_input("synthetic full-history turn #{turn}"),
            "stream" => true,
            "generate" => true
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

        {conn, websocket, _types, terminal} =
          receive_public_websocket_until_terminal(conn, websocket, ref, [])

        assert %{"type" => "response.completed"} = terminal

        assert_receive {Events,
                        %{
                          reason: "request_finalized",
                          payload: %{"request_id" => request_id, "status" => "succeeded"}
                        }},
                       5_000

        await_turn_completed!(request_id)
        {conn, websocket}
      end)

    Mint.HTTP.close(conn)
    assert FakeUpstream.count(upstream) == 2
    assert FakeUpstream.count(fallback_upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = FakeUpstream.verify!(fallback_upstream)

    assert [anchor, recovered, next] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at]
               )
             )

    assert Enum.all?(
             [anchor, recovered, next],
             &(&1.status == "succeeded" and &1.transport == "websocket")
           )

    assert recovered.retry_count == 1

    assert [failed, succeeded] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^recovered.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert failed.pool_upstream_assignment_id == setup.assignment.id
    assert failed.status == "retryable_failed"
    assert failed.response_metadata["quota_rejection_before_output"] == true
    assert succeeded.pool_upstream_assignment_id == fallback.assignment.id
    assert succeeded.status == "succeeded"

    assert Repo.one!(from(a in Attempt, where: a.request_id == ^next.id)).pool_upstream_assignment_id ==
             fallback.assignment.id
  end

  @tag :replay_race
  test "mid-stream upstream death after visible output authors exactly one error frame" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close([
          %{
            "type" => "response.created",
            "response" => %{"id" => "resp_visible_then_death", "status" => "in_progress"}
          },
          %{"type" => "response.output_text.delta", "delta" => "partial visible output"}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-visible-then-death",
          accepted_turn_state: "ws-visible-then-death",
          client_ip: "127.0.0.1"
        }
      })

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [],
        "stream" => true,
        "generate" => true
      })

    {{error_frame, state}, logs} =
      capture_native_turn_warning(fn ->
        assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

        assert {:push, {:text, created_frame}, state} = receive_socket_push(state)
        assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created_frame)

        assert {:push, {:text, delta_frame}, state} = receive_socket_push(state)
        assert %{"type" => "response.output_text.delta"} = CodexPooler.JSON.decode!(delta_frame)

        assert {:push, {:text, error_frame}, state} =
                 receive_socket_turn_done(state, @large_websocket_frame_timeout)

        assert MapSet.size(state.tasks) == 0
        {error_frame, state}
      end)

    assert error_frame ==
             ~s({"error":{"code":"upstream_request_failed",) <>
               ~s("message":"upstream request failed","param":null,) <>
               ~s("type":"server_error"},"status":502,"type":"error"})

    # Exactly one authored frame: nothing else is queued for the client. The
    # chunk pattern must carry the task pid, which is the arity production
    # actually sends.
    refute_received {:codex_response_chunk, _task_pid, _chunk}
    refute_received {:codex_response_done, _pid, _result}

    assert_native_turn_warnings(logs, 1)
    assert logs =~ "request_id=ws-visible-then-death"
    assert logs =~ "error_code=upstream_request_failed"
    assert logs =~ "visible_output=after_visible_output"
    refute logs =~ "partial visible output"

    # The socket is not closed by the failure and still serves the next turn.
    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.json_response(%{
        "id" => "resp_after_visible_death",
        "object" => "response",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      })
    )

    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    assert {:push, {:text, recovered_frame}, state} = receive_socket_push(state)
    assert %{"id" => "resp_after_visible_death"} = CodexPooler.JSON.decode!(recovered_frame)
    assert {:ok, state} = receive_socket_turn_done(state, @large_websocket_frame_timeout)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    assert_socket_response_tasks_released!()
  end

  for retry_kind <- [:none, :auth_refresh, :first_event] do
    @tag :owner_task_exception
    @tag retry_kind: retry_kind
    test "response task exception after #{retry_kind} retry fails the current attempt and admits the byte-identical resend",
         %{retry_kind: retry_kind} do
      {_result, logs} = with_log(fn -> assert_task_exception_resend(retry_kind) end)
      assert logs =~ "websocket response task failed failure_kind=exception"
      assert logs =~ "failure_reason=DBConnection.ConnectionError"
      refute logs =~ "websocket response task exception finalization failed"
    end
  end

  @tag :websocket_connect_failover
  test "a websocket handshake closed by the upstream never takes the same-assignment retry" do
    # A second connect-phase failure class through the real path: the upstream
    # accepts and closes the handshake. Any connect-phase failure either fails
    # over to the next candidate or finalizes; neither ever retries the same
    # assignment (findings#208). Like the two refused-connect tests below, this
    # drives `execute_websocket_response/4`, the internal gateway entry with a
    # writer callback where the connect-phase policy is decided, not the
    # public socket.
    port = accept_and_close_listener!(2)
    placeholder = %FakeUpstream{url: "http://127.0.0.1:#{port}"}
    setup = placeholder |> gateway_setup() |> with_failover_candidate!(placeholder)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:error, %{code: "upstream_request_failed"}} =
             execute_websocket_response(
               auth,
               task_exception_probe_payload(setup, "handshake close control"),
               %{request_id: "task-exception-handshake-close", connect_timeout_ms: 2_000},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    refute_received {:websocket_frame, _frame}
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"

    attempts =
      Repo.all(from(a in Attempt, where: a.request_id == ^request.id, order_by: a.attempt_number))

    assert [first | later] = attempts
    first_assignment_id = first.pool_upstream_assignment_id
    assert is_binary(first_assignment_id)

    # No later attempt may land on the assignment that failed: that is the
    # same-assignment retry this failure must not take.
    refute Enum.any?(later, &(&1.pool_upstream_assignment_id == first_assignment_id))

    # The kernel reports the mid-handshake close, never a refusal.
    assert %{"phase" => "connect", "reason" => reason, "upstream_committed" => false} =
             Map.take(
               first.response_metadata["transport_failure"],
               ~w(phase reason upstream_committed)
             )

    refute reason == "econnrefused"
  end

  @tag :websocket_connect_failover
  test "a refused connect on a route with no failover candidate finalizes one attempt" do
    # Same retry-safe refusal, but the route plan has no later candidate, so
    # retry policy is off (`allow_retry?` false) and no same-assignment retry runs.
    # Driven through `execute_websocket_response/4` (internal gateway entry),
    # not the public socket.
    port = reserve_closed_port!()
    setup = gateway_setup(%FakeUpstream{url: "http://127.0.0.1:#{port}"})
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:error, %{code: "upstream_request_failed"}} =
             execute_websocket_response(
               auth,
               task_exception_probe_payload(setup, "no failover candidate control"),
               %{request_id: "task-exception-no-failover", connect_timeout_ms: 2_000},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    refute_received {:websocket_frame, _frame}
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert {request.status, request.retry_count} == {"failed", 0}
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert {attempt.status, attempt.retryable} == {"failed", false}

    assert %{"phase" => "connect", "reason" => "econnrefused", "upstream_committed" => false} =
             Map.take(
               attempt.response_metadata["transport_failure"],
               ~w(phase reason upstream_committed)
             )
  end

  @tag :websocket_connect_failover
  test "a refused connect with a failover candidate moves to the next assignment, never the same one" do
    # A refused connect proves nothing left the gateway, and the route plan has
    # another candidate: the dispatcher fails over to it. The refused
    # assignment is never retried, so a pool whose second identity is healthy
    # keeps serving when the first one's endpoint is down (findings#208).
    # Driven through `execute_websocket_response/4` (internal gateway entry),
    # not the public socket.
    port = reserve_closed_port!()
    placeholder = %FakeUpstream{url: "http://127.0.0.1:#{port}"}
    setup = placeholder |> gateway_setup() |> with_failover_candidate!(placeholder)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:error, %{code: "upstream_request_failed"}} =
             execute_websocket_response(
               auth,
               task_exception_probe_payload(setup, "refused failover control"),
               %{request_id: "task-exception-refused-failover", connect_timeout_ms: 2_000},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    refute_received {:websocket_frame, _frame}
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"

    assert [first, second] =
             Repo.all(from(a in Attempt, where: a.request_id == ^request.id, order_by: a.attempt_number))

    refute first.pool_upstream_assignment_id == second.pool_upstream_assignment_id
    assert second.status == "failed"

    for attempt <- [first, second] do
      assert %{"phase" => "connect", "reason" => "econnrefused", "upstream_committed" => false} =
               Map.take(
                 attempt.response_metadata["transport_failure"],
                 ~w(phase reason upstream_committed)
               )
    end
  end

  @tag :websocket_connect_failover
  test "a refused connect leaves the candidate that serves the turn routable, in either order" do
    # 208-11 asks for the claim itself rather than for more seeds: a refused
    # connect on the first candidate must not write route-health demotion or
    # circuit state that makes the second candidate's success order-dependent.
    # The refusal is real (a kernel-refused port), the success is real (a
    # healthy fake upstream on the sibling assignment), and the ring order is
    # pinned by the rendezvous seed rather than left to the ExUnit seed, so
    # both orders are driven in one run.
    #
    # The conclusion rests on circuits being keyed per assignment: the refused
    # connect does call `begin_candidate_circuit/2`, and it is the key that
    # keeps the sibling out of it, not the absence of a write.
    port = reserve_closed_port!()
    refused = %FakeUpstream{url: "http://127.0.0.1:#{port}"}

    healthy =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "response.created",
            "response" => %{"id" => "resp_failover_serves", "status" => "in_progress"}
          }),
          CodexPooler.JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_failover_serves",
              "status" => "completed",
              "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
            }
          })
        ])
      )

    {setup, healthy_assignment} =
      refused |> gateway_setup() |> with_returned_failover_candidate!(healthy)

    refused_assignment_id = setup.assignment.id
    healthy_assignment_id = healthy_assignment.id
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assignment_ids = [refused_assignment_id, healthy_assignment_id]

    # Refused first: the turn has to fail over to reach its answer.
    assert :ok =
             execute_websocket_response(
               auth,
               task_exception_probe_payload(setup, "refused first then served"),
               %{
                 request_id: seed_preferring_assignment(assignment_ids, refused_assignment_id),
                 connect_timeout_ms: 2_000
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    [failover_request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert failover_request.status == "succeeded"

    failover_attempts =
      Repo.all(
        from(a in Attempt,
          where: a.request_id == ^failover_request.id,
          order_by: a.attempt_number
        )
      )

    assert [first, second] = failover_attempts
    assert first.pool_upstream_assignment_id == refused_assignment_id
    assert first.status == "retryable_failed"

    assert %{"phase" => "connect", "reason" => "econnrefused"} =
             Map.take(first.response_metadata["transport_failure"], ~w(phase reason))

    assert second.pool_upstream_assignment_id == healthy_assignment_id
    assert second.status == "succeeded"

    # Whatever the refusal recorded is keyed to the assignment that refused.
    # As of this revision a refused connect writes neither a routing-circuit row
    # nor a demotion, so both sets are empty here; the assertion is written
    # against the sibling rather than against emptiness so it still holds the
    # real invariant if the refused candidate ever starts being demoted.
    refute healthy_assignment_id in circuit_assignment_ids(setup)
    refute healthy_assignment_id in demoted_assignment_ids(setup)

    # A second turn, still starting at the refused candidate, still reaches the
    # same answer: the first turn's route-health writes did not disqualify the
    # candidate that served it.
    assert :ok =
             execute_websocket_response(
               auth,
               task_exception_probe_payload(setup, "refused first again then served"),
               %{
                 request_id: seed_preferring_assignment(assignment_ids, refused_assignment_id),
                 connect_timeout_ms: 2_000
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    # Healthy first: the same pool answers without touching the refused
    # endpoint at all, so the outcome does not depend on the order.
    assert :ok =
             execute_websocket_response(
               auth,
               task_exception_probe_payload(setup, "healthy first"),
               %{
                 request_id: seed_preferring_assignment(assignment_ids, healthy_assignment_id),
                 connect_timeout_ms: 2_000
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert length(requests) == 3
    assert Enum.all?(requests, &(&1.status == "succeeded"))

    served_by =
      Repo.all(
        from(a in Attempt,
          where: a.request_id in ^Enum.map(requests, & &1.id) and a.status == "succeeded",
          select: a.pool_upstream_assignment_id
        )
      )

    assert Enum.uniq(served_by) == [healthy_assignment_id]
    assert length(served_by) == 3
  end

  defp circuit_assignment_ids(setup) do
    Repo.all(
      from(c in RoutingCircuitState,
        where: c.pool_id == ^setup.pool.id,
        select: c.pool_upstream_assignment_id,
        distinct: true
      )
    )
  end

  defp demoted_assignment_ids(setup) do
    Repo.all(
      from(d in BridgeDemotion,
        where: d.pool_id == ^setup.pool.id,
        select: d.pool_upstream_assignment_id,
        distinct: true
      )
    )
  end

  # `with_failover_candidate!/2` hides the fallback assignment; the ordering
  # claim needs its id to pin the ring seed.
  defp with_returned_failover_candidate!(setup, upstream) do
    fallback =
      gateway_upstream(setup.pool, upstream, "synthetic-ordered-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {setup, fallback.assignment}
  end

  defp assert_task_exception_resend(retry_kind) do
    barrier = make_ref()
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    CodexPooler.TestAppEnv.restore_on_exit(:settlement_pricing_test_fault)
    on_exit(&stop_registered_websocket_owner_sessions/0)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    # Strict finite scenario: the first turn streams visible output and its
    # terminal on the single physical connection, then the response task dies
    # by exception inside settlement; the client's byte-identical resend is a
    # fresh turn on the same connection. Any further send fails the fixture.
    # provenance: synthetic_adversarial
    upstream_mode =
      FakeUpstream.strict_sequence(
        task_exception_retry_prefix(retry_kind) ++
          [
            strict_native_request(
              if(retry_kind == :first_event, do: 2, else: 1),
              FakeUpstream.barrier_websocket_frames(
                [
                  CodexPooler.JSON.encode!(%{
                    "type" => "response.created",
                    "response" => %{
                      "id" => "resp_task_exception_visible",
                      "status" => "in_progress"
                    }
                  }),
                  CodexPooler.JSON.encode!(%{
                    "type" => "response.output_text.delta",
                    "delta" => "visible before task exception"
                  }),
                  CodexPooler.JSON.encode!(%{
                    "type" => "response.completed",
                    "response" => %{
                      "id" => "resp_task_exception_visible",
                      "status" => "completed",
                      "usage" => %{
                        "input_tokens" => 3,
                        "output_tokens" => 2,
                        "total_tokens" => 5
                      }
                    }
                  })
                ],
                notify: self(),
                release_ref: barrier
              )
            ),
            strict_native_request(
              if(retry_kind == :first_event, do: 2, else: 1),
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_after_task_exception",
                    "status" => "completed",
                    "usage" => %{
                      "input_tokens" => 3,
                      "output_tokens" => 1,
                      "total_tokens" => 4
                    }
                  }
                })
              ])
            )
          ]
      )

    upstream = start_upstream(upstream_mode)
    setup = task_exception_setup(upstream, retry_kind)

    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()
    thread_id = Ecto.UUID.generate()

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => thread_id,
              "thread_id" => thread_id,
              "turn_id" => "task-exception-turn",
              "request_kind" => "turn"
            })
        },
        "input" => native_text_input("task exception prompt sentinel"),
        "stream" => true,
        "generate" => true
      })

    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^barrier}, 15_000

    Application.put_env(
      :codex_pooler,
      :settlement_pricing_test_fault,
      {setup.pool.id, %DBConnection.ConnectionError{message: "synthetic pool exhaustion"}}
    )

    assert :ok = FakeUpstream.release_remaining_frames(upstream, barrier)
    assert_receive {:fake_upstream_frame_barrier, 3, _handler, ^barrier}, 15_000

    {conn, _websocket, seen_types, failure_frame} =
      receive_public_websocket_until_error(conn, websocket, ref, [])

    assert "response.output_text.delta" in seen_types

    assert %{
             "type" => "error",
             "status" => 500,
             "error" => %{"code" => "websocket_response_task_failed"}
           } = failure_frame

    Application.delete_env(:codex_pooler, :settlement_pricing_test_fault)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

    attempts =
      Repo.all(from(a in Attempt, where: a.request_id == ^request.id, order_by: a.attempt_number))

    attempt = List.last(attempts)
    assert attempt.attempt_number == if(retry_kind == :none, do: 1, else: 2)

    assert Enum.all?(
             attempts,
             &(&1.pool_upstream_assignment_id == hd(attempts).pool_upstream_assignment_id)
           )

    assert_task_exception_first_attempt!(retry_kind, attempts)

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    refute is_nil(turn.first_visible_output_at)

    # The client disconnects; the old socket's cleanup completes before the
    # byte-identical resend, as in the incident's reconnect sequence.
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    assert %{downstream: %{pid: downstream_pid}} = :sys.get_state(owner_pid)
    downstream_monitor = Process.monitor(downstream_pid)

    {resend_outcome, log} =
      with_log(fn ->
        Mint.HTTP.close(conn)

        assert_receive {:DOWN, ^downstream_monitor, :process, ^downstream_pid, _reason},
                       @connection_shutdown_timeout_ms

        {retry_conn, retry_websocket, retry_ref} =
          public_websocket_connect!(port, setup, turn_state)

        {retry_conn, retry_websocket} =
          public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, payload)

        {retry_conn, _retry_websocket, retry_frame} =
          public_websocket_receive_text!(retry_conn, retry_websocket, retry_ref)

        Mint.HTTP.close(retry_conn)

        case CodexPooler.JSON.decode!(retry_frame) do
          %{"type" => "response.completed", "response" => %{"id" => id}} ->
            {:completed, id}

          %{"type" => "error", "status" => status, "error" => %{"code" => code}} ->
            {:error, status, code}
        end
      end)

    refute log =~ "stale_owner_cleanup"
    refute log =~ "websocket replay rejection"
    refute log =~ "task exception prompt sentinel"

    assert %{
             request_status: request.status,
             request_error: request.last_error_code,
             request_usage: request.usage_status,
             attempt_status: attempt.status,
             attempt_error: attempt.network_error_code,
             turn_status: turn.status,
             turn_error: turn.error_code,
             turn_final_attempt: turn.final_attempt_id,
             resend: resend_outcome
           } == %{
             request_status: "failed",
             request_error: "owner_task_exception",
             request_usage: "usage_unknown",
             attempt_status: "failed",
             attempt_error: "owner_task_exception",
             turn_status: "failed",
             turn_error: "owner_task_exception",
             turn_final_attempt: attempt.id,
             resend: {:completed, "resp_after_task_exception"}
           }

    assert [_failed, resend] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at]
               )
             )

    assert resend.id != request.id
    resend_id = resend.id

    # The completed frame reaches the client before the successor settles.
    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => ^resend_id, "status" => "succeeded"}
                    }},
                   @websocket_frame_timeout

    assert Repo.get!(Request, resend.id).status == "succeeded"

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
             :count
           ) == 2

    # Health neutral: a task exception is not backend evidence.
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
    assert FakeUpstream.count(upstream) == if(retry_kind == :none, do: 2, else: 3)

    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp assert_task_exception_first_attempt!(:none, _attempts), do: :ok

  defp assert_task_exception_first_attempt!(retry_kind, attempts) do
    assert [first, _retry] = attempts
    assert first.status == "retryable_failed"

    expected_first_error =
      case retry_kind do
        :auth_refresh -> "upstream_unauthorized"
        :first_event -> "websocket_connection_limit_reached"
      end

    assert first.network_error_code == expected_first_error
  end

  # A port nothing listens on: bound once to learn its number, closed again,
  # then probed to prove the kernel refuses it before the test relies on that.
  # Binding and closing alone has a TOCTOU window in which a concurrent
  # partition can take the freed port, which would turn a refused-connect test
  # into a hang or an unrelated failure (findings#208). The probe does not
  # close the window, it bounds it: a port that no longer refuses is discarded
  # and a fresh one is drawn, and exhausting the attempts fails loudly with the
  # real cause instead of leaving a mystery timeout.
  @closed_port_attempts 10
  @closed_port_probe_timeout_ms 200

  defp reserve_closed_port!(attempts \\ @closed_port_attempts) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    case :gen_tcp.connect(
           {127, 0, 0, 1},
           port,
           [:binary, active: false],
           @closed_port_probe_timeout_ms
         ) do
      {:error, :econnrefused} ->
        port

      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        retry_closed_port!(attempts, port, :accepted)

      {:error, reason} ->
        retry_closed_port!(attempts, port, reason)
    end
  end

  defp retry_closed_port!(attempts, _port, _reason) when attempts > 1,
    do: reserve_closed_port!(attempts - 1)

  defp retry_closed_port!(_attempts, port, reason) do
    flunk(
      "no refusing loopback port after #{@closed_port_attempts} attempts; " <>
        "last port #{port} answered #{inspect(reason)}"
    )
  end

  # A listener that accepts `count` connections and closes each immediately
  # without a byte of HTTP: the gateway sees the socket close mid-handshake.
  defp accept_and_close(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} -> :gen_tcp.close(socket)
      {:error, _closed} -> :ok
    end
  end

  defp accept_and_close_listener!(count) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    # Not linked: a listener closed by the on_exit below ends the acceptor with
    # an accept error, which must not take the test process down with it.
    acceptor = spawn(fn -> Enum.each(1..count, fn _ -> accept_and_close(listener) end) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp task_exception_probe_payload(setup, marker) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input(marker),
      "stream" => true,
      "generate" => true
    })
  end

  defp task_exception_setup(upstream, :first_event),
    do: upstream |> gateway_setup() |> with_failover_candidate!(upstream)

  defp task_exception_setup(upstream, :auth_refresh) do
    setup = gateway_setup(upstream)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "synthetic-refresh-token"
             })

    setup
  end

  defp task_exception_setup(upstream, :none), do: gateway_setup(upstream)

  # Adds a second route candidate on a fallback identity that shares the
  # upstream. What a retry does with it depends on the failure class: the
  # same-assignment retries (auth refresh, connection-limit first event) stay
  # on the first assignment, while a connect-phase failure fails over to it.
  defp with_failover_candidate!(setup, upstream) do
    fallback = gateway_upstream(setup.pool, upstream, "synthetic-fallback", compact?: false)
    prime_routing_quota!(fallback.identity)

    Map.put(
      setup,
      :model,
      put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
    )
  end

  defp task_exception_retry_prefix(:none), do: []

  defp task_exception_retry_prefix(:auth_refresh) do
    [
      FakeUpstream.expect_request(
        method: "GET",
        respond:
          FakeUpstream.websocket_upgrade_error(
            %{"error" => %{"code" => "invalid_api_key"}},
            status: 401,
            headers: [{"x-openai-authorization-error", "invalid_api_key"}]
          )
      ),
      FakeUpstream.expect_request(
        method: "POST",
        path: "/oauth/token",
        respond: FakeUpstream.json_response(%{"access_token" => "synthetic-refreshed-token"})
      )
    ]
  end

  defp task_exception_retry_prefix(:first_event) do
    [
      strict_native_request(
        1,
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "error",
            "status" => 400,
            "code" => "websocket_connection_limit_reached"
          })
        ])
      )
    ]
  end

  @tag :provider_terminal_resend
  test "provider terminal failure on a text-only turn admits the byte-identical resend as one successor" do
    scenario =
      provider_terminal_resend_scenario(
        native_text_input("text only provider failure prompt sentinel"),
        "text_only"
      )

    %{request: request, resend: resend} = scenario

    assert String.starts_with?(request.correlation_id, "codex-turn:")
    assert String.starts_with?(resend.correlation_id, "client-retry-v1:")

    assert Repo.one!(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id,
               select: link.successor_request_id
             )
           ) == resend.id
  end

  for mode <- ["full", "lite"] do
    @tag :successor_active_cap
    test "#{mode} visible-output retry successor preserves capacity denial and succeeds after release" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
      on_exit(&stop_registered_websocket_owner_sessions/0)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

      frames = [
        %{"type" => "response.created", "response" => %{"id" => "resp_cap_predecessor"}},
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "synthetic reasoning"},
        %{"type" => "response.output_text.delta", "delta" => "synthetic output"},
        %{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_cap_predecessor",
            "status" => "failed",
            "error" => %{"code" => "server_error", "message" => "synthetic failure"}
          }
        }
      ]

      upstream =
        start_upstream(
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            strict_native_request_any_connection(FakeUpstream.websocket_text_frames(Enum.map(frames, &CodexPooler.JSON.encode!/1))),
            strict_native_request_any_connection(completed_response_frames("resp_cap_successor", 3, 1))
          ])
        )

      setup = gateway_setup(upstream)
      scope = model_serving_scope()
      set_model_serving_mode!(scope, setup, unquote(mode))

      assert {:ok, _} =
               Access.update_api_key_with_policy(scope, setup.api_key, %{max_active_requests: 1})

      assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      assert :ok = Events.subscribe_pool(setup.pool)

      server =
        start_supervised!({Bandit, plug: CodexPoolerWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      on_exit(fn ->
        refute Process.alive?(server)
        assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)

        CodexPooler.TestDiagnostics.puts(inspect(%{scenario: :successor_cap_cleanup, listener_stopped: true, port_closed: true}))
      end)

      {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())
      payload = stream_cut_payload(setup, native_text_input("synthetic fixture"), "active-cap")

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

        {conn, websocket, types, terminal} =
          receive_public_websocket_until_terminal(conn, websocket, ref, [])

        assert terminal["type"] == "response.failed"
        assert "response.reasoning_summary_text.delta" in types
        assert "response.output_text.delta" in types

        assert_receive {Events,
                        %{
                          reason: "request_finalized",
                          payload: %{"request_id" => predecessor_id, "status" => "failed"}
                        }},
                       15_000

        turn = await_turn_completed!(predecessor_id)
        refute is_nil(turn.first_visible_output_at)

        assert {:ok, holder} =
                 Accounting.reserve(auth, setup.model, %{
                   "model" => setup.model.exposed_model_id
                 })

        counts = successor_counts(setup)

        {conn, websocket} =
          Enum.reduce(1..2, {conn, websocket}, fn _, {conn, websocket} ->
            {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

            {conn, websocket, _, denied} =
              receive_public_websocket_until_terminal(conn, websocket, ref, [])

            assert %{
                     "type" => "error",
                     "status" => 429,
                     "error" => %{
                       "code" => "api_key_concurrency_limit_exceeded",
                       "type" => "rate_limit_error"
                     }
                   } = denied

            assert successor_counts(setup) == counts
            assert FakeUpstream.count(upstream) == 1
            {conn, websocket}
          end)

        changed_payload =
          payload
          |> CodexPooler.JSON.decode!()
          |> Map.put("input", native_text_input("changed synthetic fixture"))
          |> CodexPooler.JSON.encode!()

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, changed_payload)

        {conn, websocket, _, ineligible} =
          receive_public_websocket_until_terminal(conn, websocket, ref, [])

        assert %{"status" => 409, "error" => %{"code" => "duplicate_turn"}} = ineligible
        assert successor_counts(setup) == counts
        assert FakeUpstream.count(upstream) == 1

        assert {:ok, _} = Accounting.finalize_reservation_failure(holder.request)
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

        {conn, websocket, _, completed} =
          receive_public_websocket_until_terminal(conn, websocket, ref, [])

        assert completed["type"] == "response.completed"

        assert_receive {Events,
                        %{
                          reason: "request_finalized",
                          payload: %{"request_id" => successor_id, "status" => "succeeded"}
                        }},
                       15_000

        await_turn_completed!(successor_id)

        assert Repo.get_by!(RequestClientRetryLink,
                 predecessor_request_id: predecessor_id
               ).successor_request_id == successor_id

        assert successor_counts(setup) == %{requests: 3, links: 1, reservations: 3, attempts: 2}

        assert Accounting.LedgerReads.outstanding_reservation_count(setup.api_key.id) ==
                 0

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

        {_conn, _websocket, _, duplicate} =
          receive_public_websocket_until_terminal(conn, websocket, ref, [])

        assert %{"status" => 409, "error" => %{"code" => "duplicate_turn"}} = duplicate
        assert successor_counts(setup) == %{requests: 3, links: 1, reservations: 3, attempts: 2}
        assert FakeUpstream.count(upstream) == 2
        assert :ok = FakeUpstream.verify!(upstream)

        CodexPooler.TestDiagnostics.puts(
          inspect(%{
            scenario: :visible_output_successor_cap,
            mode: unquote(mode),
            denials: [429, 429],
            denied_rows_unchanged: true,
            changed_payload: 409,
            released_successor: 1,
            duplicate_after_success: 409,
            active: 0
          })
        )
      after
        assert {:ok, closed} = Mint.HTTP.close(conn)
        refute Mint.HTTP.open?(closed)

        CodexPooler.TestDiagnostics.puts(inspect(%{scenario: :successor_cap_cleanup, client_socket_closed: true}))
      end
    end
  end

  defp successor_counts(setup) do
    %{
      requests:
        Repo.aggregate(
          from(r in Request, where: r.pool_id == ^setup.pool.id and r.status != "rejected"),
          :count
        ),
      attempts:
        Repo.aggregate(
          from(a in Attempt,
            join: r in Request,
            on: r.id == a.request_id,
            where: r.pool_id == ^setup.pool.id
          ),
          :count
        ),
      reservations:
        Repo.aggregate(
          from(e in LedgerEntry,
            where: e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation"
          ),
          :count
        ),
      links:
        Repo.aggregate(
          from(l in RequestClientRetryLink,
            join: r in Request,
            on: r.id == l.predecessor_request_id,
            where: r.pool_id == ^setup.pool.id
          ),
          :count
        )
    }
  end

  @tag :provider_terminal_resend
  test "provider terminal failure on a tool-continuation turn admits the byte-identical resend with a derived request claim" do
    scenario =
      provider_terminal_resend_scenario(
        tool_continuation_input("tool continuation provider failure prompt sentinel"),
        "tool_continuation"
      )

    %{request: request, resend: resend, log: log} = scenario

    assert String.starts_with?(request.correlation_id, "codex-request:")
    assert String.starts_with?(resend.correlation_id, "codex-request-retry:")

    assert resend.request_metadata["client_resend"] == %{
             "predecessor_request_id" => request.id,
             "reason" => "failed_predecessor"
           }

    assert log =~ "reason_code=failed_predecessor_retry"
    assert log =~ "predecessor_request_id=#{request.id}"

    refute Repo.exists?(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id
             )
           )
  end

  @tag :stream_cut_resend
  test "lifecycle-only stream cut persists the native client retry observation with a null first_visible_at" do
    enable_owner_forwarding!()

    upstream =
      start_upstream(
        # provenance: observed findings issue 124 (lifecycle frames then a transport close without a terminal)
        FakeUpstream.strict_sequence([
          strict_native_request(1, stream_cut_frames("persisted", []))
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()

    payload =
      stream_cut_payload(
        setup,
        tool_continuation_input("persisted lifecycle cut prompt sentinel"),
        "persisted"
      )

    {_server, port} = start_public_endpoint_with_server!()

    %{conn: conn, request: request, attempt: attempt, turn: turn} =
      stream_cut_first_turn!(setup, port, turn_state, payload, "response.in_progress")

    Mint.HTTP.close(conn)

    assert request.native_client_retry_version == 1

    assert attempt.response_metadata["native_client_retry_observation"] == %{
             "version" => 1,
             "authority_complete" => true,
             "output_item_done_count" => 0,
             "output_item_done_count_saturated" => false,
             "partial_reasoning_seen" => false,
             "first_visible_at" => nil,
             "terminal_seen" => false,
             "terminal_candidate_seen" => false
           }

    assert ClientRetry.verified_lifecycle_cut?(turn, request, attempt)
    refute inspect(attempt.response_metadata) =~ "prompt sentinel"
    assert FakeUpstream.count(upstream) == 1
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :stream_cut_resend
  test "lifecycle-only stream cut on a tool-continuation turn admits the byte-identical resend with a derived request claim" do
    %{request: request, resend: resend, log: log} =
      stream_cut_resend_scenario(
        tool_continuation_input("tool continuation lifecycle cut prompt sentinel"),
        "tool_continuation",
        expect: :admitted
      )

    assert String.starts_with?(request.correlation_id, "codex-request:")

    assert {:ok, resend.correlation_id} ==
             ClientRetry.deterministic_failed_predecessor_claim(
               request.correlation_id,
               request.id
             )

    assert resend.request_metadata["client_resend"] == %{
             "predecessor_request_id" => request.id,
             "reason" => "failed_predecessor"
           }

    assert log =~ "websocket client resend admitted stage=websocket_turn_claim"
    assert log =~ "reason_code=failed_predecessor_retry"
    assert log =~ "predecessor_request_id=#{request.id}"
    assert log =~ "predecessor_shape=lifecycle_cut"

    refute Repo.exists?(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id
             )
           )
  end

  @tag :stream_cut_resend
  test "stream cut after one completed output item keeps the duplicate turn fence for the byte-identical resend" do
    completed_item =
      CodexPooler.JSON.encode!(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "synthetic completed item"}]
        }
      })

    %{request: request, attempt: attempt, log: log} =
      stream_cut_resend_scenario(
        tool_continuation_input("completed item cut prompt sentinel"),
        "completed_item",
        expect: :rejected,
        pre_close_frames: [completed_item],
        last_upstream_event_type: "response.output_item"
      )

    assert %{"output_item_done_count" => 1, "first_visible_at" => first_visible_at} =
             attempt.response_metadata["native_client_retry_observation"]

    assert is_binary(first_visible_at)
    assert String.starts_with?(request.correlation_id, "codex-request:")

    assert log =~
             "websocket replay rejection stage=websocket_turn_claim reason_code=reservation_duplicate"

    assert log =~ "resend_disposition=terminal_predecessor"
    refute log =~ "websocket client resend admitted"
  end

  @tag :stream_cut_resend
  test "lifecycle-only stream cut on a text-only turn admits the byte-identical resend as one client-retry successor" do
    %{request: request, resend: resend} =
      stream_cut_resend_scenario(
        native_text_input("text only lifecycle cut prompt sentinel"),
        "text_only",
        expect: :admitted
      )

    assert String.starts_with?(request.correlation_id, "codex-turn:")
    assert String.starts_with?(resend.correlation_id, "client-retry-v1:")

    assert Repo.one!(
             from(link in CodexPooler.Accounting.RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id,
               select: link.successor_request_id
             )
           ) == resend.id
  end

  @tag :provider_terminal_resend
  test "byte-identical tool-continuation resends after a provider terminal failure admit exactly one lifecycle" do
    # Strict finite scenario: the first turn ends with the provider terminal,
    # then two concurrent byte-identical resends race for the derived claim.
    # Exactly one reaches the second upstream response; a third send fails the
    # fixture.
    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (2026-09-09 23:43 UTC response.failed server_error)
        FakeUpstream.strict_sequence([
          strict_native_request_any_connection(provider_terminal_failure_frames("concurrent")),
          strict_native_request_any_connection(completed_response_frames("resp_after_concurrent_resend", 3, 1))
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "provider-failure-concurrent"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      tool_continuation_payload(
        setup.model.exposed_model_id,
        "provider-failure-concurrent-turn",
        "concurrent resend prompt sentinel"
      )

    assert :ok =
             execute_websocket_response(auth, payload, opts, fn frame ->
               send(self(), {:websocket_frame, :first, frame})
             end)

    assert "response.failed" in received_frame_types(:first)
    assert [failed] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert failed.status == "failed"
    failed_id = failed.id

    parent = self()

    tasks =
      for label <- [:first, :second] do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:resend_task_ready, label, self()})

          receive do
            :run_resend -> :ok
          after
            5_000 -> flunk("resend task #{label} was not released")
          end

          execute_websocket_response(auth, payload, opts, fn frame ->
            send(parent, {:websocket_frame, label, frame})
          end)
        end)
      end

    task_pids =
      for _label <- [:first, :second] do
        assert_receive {:resend_task_ready, _label, pid}, 5_000
        pid
      end

    Enum.each(task_pids, &send(&1, :run_resend))
    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &match?(:ok, &1)) == 1
    assert Enum.count(results, &match?({:error, %{status: 409, code: "duplicate_turn"}}, &1)) == 1

    [{admitted_label, :ok}] =
      Enum.filter(Enum.zip([:first, :second], results), &match?({_label, :ok}, &1))

    assert "response.completed" in received_frame_types(admitted_label)
    refute_received {:websocket_frame, _label, _frame}

    assert [%Request{id: ^failed_id}, admitted] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at]
               )
             )

    assert String.starts_with?(admitted.correlation_id, "codex-request-retry:")
    assert admitted.request_metadata["client_resend"]["predecessor_request_id"] == failed_id
    assert admitted.status == "succeeded"

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             2

    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The same fence, across the one thing that used to move underneath it. After
  # a remote compaction the released client advances its window
  # (`compact_remote_v2.rs:323`) and `x-codex-window-id` is
  # `"{thread_id}:{window_number}"` (`session/mod.rs:4449-4459`), so the resend
  # of the turn that compacted carries a new window while the thread, the
  # `turn_id` and the authorized history are unchanged. The session key prefers
  # the window since `6441e83d`, so that resend landed in a SECOND codex session
  # where a claim named after the session UUID could not meet its predecessor,
  # and the provider was asked the same history twice
  # (icoretech/codex-pooler-findings#250).
  @tag :post_compaction_window_rotation
  test "an identical native resend after a window rotation is fenced and buys no second dispatch" do
    upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_window_rotation_websocket"}))

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    thread = Ecto.UUID.generate()

    {:ok, window_one} = start_window_session(auth, thread, 1)
    {:ok, window_two} = start_window_session(auth, thread, 2)

    # The rotation really does split the session: this is the precondition the
    # fence used to lose, not an artefact of the test.
    refute window_one.id == window_two.id

    turn_id = "post-compaction-window-rotation-turn"
    opening = post_compaction_turn_payload(setup, thread, 1, turn_id)

    assert :ok =
             execute_websocket_response(
               auth,
               opening,
               %{request_id: "window-one-connection", codex_session: window_one},
               fn frame -> send(self(), {:websocket_frame, :opening, frame}) end
             )

    assert_received {:websocket_frame, :opening, _opening_frame}
    assert FakeUpstream.count(upstream) == 1

    resend = post_compaction_turn_payload(setup, thread, 2, turn_id)

    {result, log} =
      with_info_log(fn ->
        execute_websocket_response(
          auth,
          resend,
          %{request_id: "window-two-connection", codex_session: window_two},
          fn frame -> send(self(), {:websocket_frame, :resend, frame}) end
        )
      end)

    assert {:error, %{status: 409, code: "duplicate_turn"}} = result
    refute_received {:websocket_frame, :resend, _resend_frame}
    assert log =~ "reason_code=reservation_duplicate"
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1

    # A genuinely new turn of the rotated window is still ordinary work, and it
    # is still filed under the window's own session: only the claim follows the
    # thread, routing and affinity keep following the window.
    successor = post_compaction_turn_payload(setup, thread, 2, turn_id <> "-successor")

    assert :ok =
             execute_websocket_response(
               auth,
               successor,
               %{request_id: "window-two-successor-connection", codex_session: window_two},
               fn frame -> send(self(), {:websocket_frame, :successor, frame}) end
             )

    assert_received {:websocket_frame, :successor, _successor_frame}
    assert FakeUpstream.count(upstream) == 2

    assert [window_one.id, window_two.id] ==
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at],
                 select: fragment("?->>'codex_session_id'", r.request_metadata)
               )
             )
  end

  @tag :provider_terminal_resend
  test "byte-identical resend while the first turn is still in progress keeps the duplicate turn fence" do
    release_ref = make_ref()

    # Strict finite scenario: the only upstream connection sends no terminal
    # until released, so the first turn stays in progress while the resend is
    # fenced; the fixture refuses any second send.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request_any_connection(
            FakeUpstream.websocket_close_without_terminal_barrier(
              notify: self(),
              release_ref: release_ref,
              code: 1001,
              reason: "synthetic close after the fenced resend"
            )
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "provider-failure-in-progress"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      tool_continuation_payload(
        setup.model.exposed_model_id,
        "in-progress-fence-turn",
        "in progress resend prompt sentinel"
      )

    parent = self()

    first =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        execute_websocket_response(auth, payload, opts, fn frame ->
          send(parent, {:websocket_frame, :first, frame})
        end)
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   5_000

    {result, log} =
      with_info_log(fn ->
        execute_websocket_response(auth, payload, opts, fn frame ->
          send(parent, {:websocket_frame, :resend, frame})
        end)
      end)

    assert {:error, %{status: 409, code: "duplicate_turn"}} = result
    refute_received {:websocket_frame, :resend, _frame}
    assert log =~ "reason_code=reservation_duplicate"
    assert log =~ "resend_disposition=active_predecessor"
    refute log =~ "in progress resend prompt sentinel"

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})
    first_result = Task.await(first, 10_000)
    assert match?(:ok, first_result) or match?({:error, %{status: _status}}, first_result)

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1

    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :provider_terminal_resend
  test "byte-identical resend after the client retry window keeps the duplicate turn fence" do
    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (2026-09-09 23:43 UTC response.failed server_error)
        FakeUpstream.strict_sequence([
          strict_native_request_any_connection(provider_terminal_failure_frames("expired"))
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "provider-failure-expired"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      tool_continuation_payload(
        setup.model.exposed_model_id,
        "expired-resend-turn",
        "expired resend prompt sentinel"
      )

    assert :ok = execute_websocket_response(auth, payload, opts, fn _frame -> :ok end)
    assert [failed] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert failed.status == "failed"

    # The retry window is measured from the predecessor's completion; move it
    # just past the 30 s client retry window instead of waiting.
    expired_at = DateTime.add(failed.completed_at, -31, :second)

    Repo.update_all(from(r in Request, where: r.id == ^failed.id),
      set: [completed_at: expired_at]
    )

    {result, log} =
      with_info_log(fn ->
        execute_websocket_response(auth, payload, opts, fn frame ->
          send(self(), {:websocket_frame, :resend, frame})
        end)
      end)

    assert {:error, %{status: 409, code: "duplicate_turn"}} = result
    refute_received {:websocket_frame, :resend, _frame}
    assert log =~ "reason_code=reservation_duplicate"
    assert log =~ "resend_disposition=retry_expired"
    refute log =~ "expired resend prompt sentinel"

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # Strict finite scenario shared by both resend paths: the first turn ends
  # with the provider's own `response.failed` terminal on the single physical
  # upstream connection, then the client's byte-identical resend after a
  # reconnect is admitted as one fresh turn on that connection. Any further
  # send fails the fixture.
  defp provider_terminal_resend_scenario(input, label) do
    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()

      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    completed_response_id = "resp_after_provider_failure_#{label}"

    upstream =
      start_upstream(
        # provenance: observed runbook terminal-failure resend (2026-09-09 23:43 UTC response.failed server_error)
        FakeUpstream.strict_sequence([
          strict_native_request(1, provider_terminal_failure_frames(label)),
          strict_native_request(1, completed_response_frames(completed_response_id, 3, 1))
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()
    thread_id = Ecto.UUID.generate()

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => thread_id,
              "thread_id" => thread_id,
              "turn_id" => "provider-failure-#{label}-turn",
              "request_kind" => "turn"
            })
        },
        "input" => input,
        "stream" => true,
        "generate" => true
      })

    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

    {conn, _websocket, _seen_types, failure_frame} =
      receive_public_websocket_until_terminal(conn, websocket, ref, [])

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "server_error"}}
           } = failure_frame

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => failed_request_id, "status" => "failed"}
                    }},
                   @websocket_frame_timeout

    request = Repo.get!(Request, failed_request_id)
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    turn = await_turn_completed!(request.id)

    # The predecessor shape the resend policy verifies: every row is failed
    # with the provider code and the turn points at the failed attempt.
    assert %{
             request_status: request.status,
             request_error: request.last_error_code,
             attempt_status: attempt.status,
             attempt_error: attempt.network_error_code,
             attempt_generation: attempt.replay_generation,
             turn_status: turn.status,
             turn_error: turn.error_code,
             turn_final_attempt: turn.final_attempt_id
           } == %{
             request_status: "failed",
             request_error: "server_error",
             attempt_status: "failed",
             attempt_error: "server_error",
             attempt_generation: 0,
             turn_status: "failed",
             turn_error: "server_error",
             turn_final_attempt: attempt.id
           }

    refute is_nil(request.completed_at)
    refute is_nil(turn.completed_at)

    # The client disconnects; the old socket's cleanup completes before the
    # byte-identical resend, as in the incident's reconnect sequence.
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    assert %{downstream: %{pid: downstream_pid}} = :sys.get_state(owner_pid)
    downstream_monitor = Process.monitor(downstream_pid)

    {resend_outcome, log} =
      with_info_log(fn ->
        Mint.HTTP.close(conn)

        assert_receive {:DOWN, ^downstream_monitor, :process, ^downstream_pid, _reason},
                       @connection_shutdown_timeout_ms

        {retry_conn, retry_websocket, retry_ref} =
          public_websocket_connect!(port, setup, turn_state)

        {retry_conn, retry_websocket} =
          public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, payload)

        {retry_conn, _retry_websocket, _types, terminal} =
          receive_public_websocket_until_terminal(retry_conn, retry_websocket, retry_ref, [])

        Mint.HTTP.close(retry_conn)

        case terminal do
          %{"type" => "response.completed", "response" => %{"id" => id}} ->
            {:completed, id}

          %{"type" => "error", "status" => status, "error" => %{"code" => code}} ->
            {:error, status, code}

          %{"type" => "response.failed"} = failed ->
            {:failed, get_in(failed, ["response", "error", "code"])}
        end
      end)

    assert resend_outcome == {:completed, completed_response_id}
    refute log =~ "websocket replay rejection"
    refute log =~ "prompt sentinel"

    assert [%Request{id: ^failed_request_id}, resend] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^setup.pool.id,
                 order_by: [asc: r.admitted_at]
               )
             )

    resend_id = resend.id

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => ^resend_id, "status" => "succeeded"}
                    }},
                   @websocket_frame_timeout

    resend = Repo.get!(Request, resend_id)
    assert resend.status == "succeeded"

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
             :count
           ) == 2

    # Health neutral: the client's resend is not backend evidence.
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)

    %{setup: setup, request: request, attempt: attempt, turn: turn, resend: resend, log: log}
  end

  # Strict finite scenario for a stream cut: the first turn receives
  # `response.created`, `response.in_progress`, and any `pre_close_frames`, then
  # the upstream drops the TCP connection without a terminal or a close frame
  # (findings issue 124). An admitted byte-identical resend after the client
  # reconnects is the only other send and arrives on a replacement connection.
  defp stream_cut_resend_scenario(input, label, opts) do
    expect = Keyword.fetch!(opts, :expect)
    pre_close_frames = Keyword.get(opts, :pre_close_frames, [])
    enable_owner_forwarding!()

    completed_response_id = "resp_after_stream_cut_#{label}"

    replies =
      case expect do
        :admitted ->
          [
            strict_native_request(1, stream_cut_frames(label, pre_close_frames)),
            strict_native_request(2, completed_response_frames(completed_response_id, 3, 1))
          ]

        :rejected ->
          [strict_native_request(1, stream_cut_frames(label, pre_close_frames))]
      end

    upstream =
      start_upstream(
        # provenance: observed findings issue 124 (lifecycle frames, transport close; items and resend reply synthetic)
        FakeUpstream.strict_sequence(replies)
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()
    payload = stream_cut_payload(setup, input, label)

    # The attempt records the bounded event family, not the raw frame type.
    last_event_type = Keyword.get(opts, :last_upstream_event_type, "response.in_progress")

    {_server, port} = start_public_endpoint_with_server!()

    %{conn: conn, request: request, attempt: attempt, turn: turn} =
      stream_cut_first_turn!(setup, port, turn_state, payload, last_event_type)

    failed_request_id = request.id

    # The client disconnects; the old socket's cleanup completes before the
    # byte-identical resend, as in the incident's reconnect sequence.
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    assert %{downstream: %{pid: downstream_pid}} = :sys.get_state(owner_pid)
    downstream_monitor = Process.monitor(downstream_pid)

    {resend_outcome, log} =
      with_info_log(fn ->
        Mint.HTTP.close(conn)

        assert_receive {:DOWN, ^downstream_monitor, :process, ^downstream_pid, _reason},
                       @connection_shutdown_timeout_ms

        {retry_conn, retry_websocket, retry_ref} =
          public_websocket_connect!(port, setup, turn_state)

        {retry_conn, retry_websocket} =
          public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, payload)

        {retry_conn, _retry_websocket, _types, terminal} =
          receive_public_websocket_until_terminal(retry_conn, retry_websocket, retry_ref, [])

        Mint.HTTP.close(retry_conn)

        case terminal do
          %{"type" => "response.completed", "response" => %{"id" => id}} ->
            {:completed, id}

          %{"type" => "error", "status" => status, "error" => %{"code" => code}} ->
            {:error, status, code}

          %{"type" => "response.failed"} = failed ->
            {:failed, get_in(failed, ["response", "error", "code"])}
        end
      end)

    refute log =~ "prompt sentinel"

    resend =
      case expect do
        :admitted ->
          assert resend_outcome == {:completed, completed_response_id}
          refute log =~ "websocket replay rejection"

          assert [%Request{id: ^failed_request_id}, resend] =
                   Repo.all(
                     from(r in Request,
                       where: r.pool_id == ^setup.pool.id,
                       order_by: [asc: r.admitted_at]
                     )
                   )

          resend_id = resend.id

          assert_receive {Events,
                          %{
                            reason: "request_finalized",
                            payload: %{"request_id" => ^resend_id, "status" => "succeeded"}
                          }},
                         @websocket_frame_timeout

          assert Repo.aggregate(
                   from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
                   :count
                 ) == 2

          assert FakeUpstream.count(upstream) == 2
          Repo.get!(Request, resend_id)

        :rejected ->
          assert resend_outcome == {:error, 409, "duplicate_turn"}

          assert [%Request{id: ^failed_request_id}] =
                   Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

          assert Repo.aggregate(
                   from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
                   :count
                 ) == 1

          assert FakeUpstream.count(upstream) == 1
          nil
      end

    assert :ok = FakeUpstream.verify!(upstream)

    %{setup: setup, request: request, attempt: attempt, turn: turn, resend: resend, log: log}
  end

  # Runs the cut turn over the public endpoint and returns the finalized rows.
  # The predecessor shape both resend paths judge: every row failed with
  # `upstream_stream_error`, the turn counted `response.created` as visible,
  # and the attempt carries the exact Mint closed evidence with no terminal.
  defp stream_cut_first_turn!(setup, port, turn_state, payload, last_event_type) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)

    {conn, _websocket, seen_types, failure_frame} =
      receive_public_websocket_until_terminal(conn, websocket, ref, [])

    assert %{"type" => "error", "status" => 502} = failure_frame
    assert ["response.created", "response.in_progress" | _rest] = seen_types

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"request_id" => failed_request_id, "status" => "failed"}
                    }},
                   @websocket_frame_timeout

    request = Repo.get!(Request, failed_request_id)
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    turn = await_turn_completed!(request.id)

    assert %{
             request: {request.status, request.last_error_code},
             attempt: {attempt.status, attempt.network_error_code, attempt.replay_generation},
             turn: {turn.status, turn.error_code, turn.final_attempt_id}
           } == %{
             request: {"failed", "upstream_stream_error"},
             attempt: {"failed", "upstream_stream_error", 0},
             turn: {"failed", "upstream_stream_error", attempt.id}
           }

    refute is_nil(turn.first_visible_output_at)

    assert Map.take(
             attempt.response_metadata["transport_failure"],
             ~w(phase termination_source exception reason transport_signal terminal_seen terminal_candidate_seen last_upstream_event_type)
           ) == %{
             "phase" => "receive",
             "termination_source" => "mint_transport_error",
             "exception" => "Mint.TransportError",
             "reason" => "closed",
             "transport_signal" => "tcp_closed",
             "terminal_seen" => false,
             "terminal_candidate_seen" => false,
             "last_upstream_event_type" => last_event_type
           }

    %{conn: conn, request: request, attempt: attempt, turn: turn}
  end

  defp stream_cut_frames(label, pre_close_frames) do
    response_id = "resp_stream_cut_#{label}"

    FakeUpstream.websocket_text_frames_then_abrupt_close(
      [
        CodexPooler.JSON.encode!(%{
          "type" => "response.created",
          "response" => %{"id" => response_id, "status" => "in_progress"}
        }),
        CodexPooler.JSON.encode!(%{
          "type" => "response.in_progress",
          "response" => %{"id" => response_id, "status" => "in_progress"}
        })
      ] ++ pre_close_frames
    )
  end

  defp stream_cut_payload(setup, input, label) do
    thread_id = Ecto.UUID.generate()

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "session_id" => thread_id,
            "thread_id" => thread_id,
            "turn_id" => "stream-cut-#{label}-turn",
            "request_kind" => "turn"
          })
      },
      "input" => input,
      "stream" => true,
      "generate" => true
    })
  end

  defp enable_owner_forwarding! do
    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()

      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp provider_terminal_failure_frames(label) do
    response_id = "resp_provider_failure_#{label}"

    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "response.created",
        "response" => %{"id" => response_id, "status" => "in_progress"}
      }),
      CodexPooler.JSON.encode!(%{
        "type" => "response.failed",
        "response" => %{
          "id" => response_id,
          "status" => "failed",
          "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}
        }
      })
    ])
  end

  defp completed_response_frames(response_id, input_tokens, output_tokens) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "usage" => %{
            "input_tokens" => input_tokens,
            "output_tokens" => output_tokens,
            "total_tokens" => input_tokens + output_tokens
          }
        }
      })
    ])
  end

  defp strict_native_request_any_connection(respond) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      json: [valid: true, equals: %{"type" => "response.create"}],
      respond: respond
    )
  end

  defp tool_continuation_input(text) do
    native_text_input(text) ++
      [
        %{
          "type" => "function_call",
          "call_id" => "call_provider_failure_resend",
          "name" => "shell",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_provider_failure_resend",
          "output" => "synthetic tool output sentinel"
        }
      ]
  end

  defp start_window_session(auth, thread, window_number) do
    Gateway.start_codex_session(auth, %{
      session_header: "#{thread}:#{window_number}",
      session_header_source: "x-codex-window-id"
    })
  end

  defp post_compaction_turn_payload(setup, thread, window_number, turn_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{
        "turn_id" => turn_id,
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "session_id" => thread,
            "thread_id" => thread,
            "turn_id" => turn_id,
            "window_id" => "#{thread}:#{window_number}",
            "window_number" => window_number,
            "request_kind" => "turn"
          })
      },
      "input" => native_text_input("post-compaction window rotation sentinel"),
      "stream" => true,
      "generate" => true
    })
  end

  defp tool_continuation_payload(model, turn_id, text) do
    thread_id = Ecto.UUID.generate()

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model,
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "session_id" => thread_id,
            "thread_id" => thread_id,
            "turn_id" => turn_id,
            "request_kind" => "turn"
          })
      },
      "input" => tool_continuation_input(text),
      "stream" => true,
      "generate" => true
    })
  end

  defp await_turn_completed!(request_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    case Repo.all(from(t in CodexTurn, where: t.request_id == ^request_id)) do
      [%CodexTurn{status: status} = turn] when status != "in_progress" ->
        turn

      turns ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            5 -> await_turn_completed!(request_id, deadline)
          end
        else
          flunk("expected the failed turn to complete, got #{inspect(Enum.map(turns, & &1.status))}")
        end
    end
  end

  defp received_frame_types(label, acc \\ []) do
    receive do
      {:websocket_frame, ^label, frame} ->
        received_frame_types(label, [CodexPooler.JSON.decode!(frame)["type"] | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp receive_public_websocket_until_terminal(conn, websocket, ref, seen_types) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal
      when type in ["response.completed", "response.failed", "error"] ->
        {conn, websocket, Enum.reverse(seen_types), terminal}

      %{"type" => type} ->
        receive_public_websocket_until_terminal(conn, websocket, ref, [type | seen_types])
    end
  end

  defp receive_public_websocket_until_error(conn, websocket, ref, seen_types) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => "error"} = error ->
        {conn, websocket, Enum.reverse(seen_types), error}

      %{"type" => type} ->
        receive_public_websocket_until_error(conn, websocket, ref, [type | seen_types])
    end
  end
end
