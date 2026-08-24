defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionTriggerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @turn_state_param "client_metadata.x-codex-turn-state"
  @detection_timeout_ms 15_000

  test "ordinary native frames keep permissive malformed turn-state behavior" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ordinary_permissive_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Websocket.start_codex_session(auth, %{})

    assert :ok =
             Service.execute_websocket_response(
               auth,
               ordinary_payload(setup, %{
                 "client_metadata" => %{"x-codex-turn-state" => ["still-permissive"]}
               }),
               RequestOptions.for_websocket(%{codex_session: session}),
               fn frame ->
                 unless StreamProtocol.internal_control_event?(frame) do
                   send(self(), {:frame, frame})
                 end
               end
             )

    assert_receive {:frame, frame}, @detection_timeout_ms
    assert %{"id" => "resp_ordinary_permissive_turn_state"} = Jason.decode!(frame)
    assert FakeUpstream.count(upstream) == 1
  end

  test "direct socket rejects malformed bridge turn state before side effects and remains reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_invalid_bridge_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = direct_socket(auth, "direct-invalid-bridge-turn-state")

    try do
      state =
        Enum.reduce(invalid_turn_states(), state, fn turn_state, state ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in(
                     {compact_payload(setup, turn_state), [opcode: :text]},
                     state
                   )

          assert {:push, {:text, error_frame}, next_state} = receive_socket_message(state)
          assert_invalid_turn_state_error(error_frame)
          assert FakeUpstream.count(upstream) == 0
          assert Repo.aggregate(Request, :count) == 0
          assert Repo.aggregate(Attempt, :count) == 0
          assert Repo.aggregate(LedgerEntry, :count) == 0
          next_state
        end)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {ordinary_payload(setup), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_socket_message(state)
      assert %{"id" => "resp_after_invalid_bridge_turn_state"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)
      assert FakeUpstream.count(upstream) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "owner-forwarded socket rejects malformed bridge turn state before retarget and remains reusable" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_owner_after_invalid_bridge_turn_state",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "owner-invalid-bridge-turn-state",
          accepted_turn_state: "owner-upgrade-turn-state",
          client_ip: "127.0.0.1"
        }
      })

    original_session_id = state.codex_session.id

    try do
      state =
        Enum.reduce(edge_wrapped_invalid_turn_states(), state, fn turn_state, state ->
          {:ok, target_state} =
            CodexResponsesSocket.init(%{
              auth: auth,
              opts: %{
                request_id:
                  "owner-invalid-bridge-turn-state-target-#{System.unique_integer([:positive])}",
                accepted_turn_state: turn_state,
                client_ip: "127.0.0.1"
              }
            })

          target_session_id = target_state.codex_session.id

          try do
            assert {:ok, state} =
                     CodexResponsesSocket.handle_in(
                       {compact_payload(setup, turn_state), [opcode: :text]},
                       state
                     )

            assert state.codex_session.id == original_session_id
            refute state.codex_session.id == target_session_id
            assert {:push, {:text, error_frame}, next_state} = receive_socket_message(state)
            assert_invalid_turn_state_error(error_frame)
            assert next_state.codex_session.id == original_session_id
            refute next_state.codex_session.id == target_session_id
            assert_no_invalid_turn_state_side_effects(upstream)
            next_state
          after
            CodexResponsesSocket.terminate(:closed, target_state)
          end
        end)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {ordinary_payload(setup), [opcode: :text]},
                 state
               )

      assert {:push, {:text, frame}, state} = receive_socket_message(state)
      assert %{"id" => "resp_owner_after_invalid_bridge_turn_state"} = Jason.decode!(frame)
      assert {:ok, _state} = receive_socket_completion(state)
      assert FakeUpstream.count(upstream) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "buffered native bridge forwards one validated frame turn state and adapts once after settlement" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_native_buffered_compaction",
          "output" => [
            %{
              "type" => "compaction",
              "encrypted_content" => "synthetic-native-buffered-encrypted"
            }
          ],
          "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
        })
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      direct_socket(auth, "native-buffered-success",
        accepted_turn_state: "upgrade-turn-state",
        forwarded_headers: [
          {"X-Codex-Turn-State", "stale-one"},
          {"x-codex-turn-state", "stale-two"}
        ]
      )

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {compact_payload(setup, "  frame-turn-state  "), [opcode: :text]},
                 state
               )

      assert {:push, {:text, done_frame}, state} = receive_socket_message(state)
      assert {:push, {:text, completed_frame}, state} = receive_socket_message(state)
      assert {:ok, _state} = receive_socket_done(state)

      assert %{"type" => "response.output_item.done", "item" => item} = Jason.decode!(done_frame)

      assert %{
               "type" => "response.completed",
               "response" => %{"output" => [^item]}
             } = Jason.decode!(completed_frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "POST"
      assert captured.path == "/backend-api/codex/responses"

      assert Enum.filter(captured.headers, fn {name, _value} ->
               String.downcase(name) == "x-codex-turn-state"
             end) == [{"x-codex-turn-state", "frame-turn-state"}]

      assert [request] = Repo.all(Request)
      assert request.status == "succeeded"

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.status == "succeeded"
      assert settlement_count(request.id) == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "invalid buffered native compact bodies fail before success settlement" do
    cases = [
      {FakeUpstream.malformed_json("{malformed-native-compact", 200),
       "upstream compact response was not valid JSON"},
      {FakeUpstream.json_response(%{"id" => "resp_missing_native_compact_content"}),
       "upstream compact response did not include encrypted compaction content"}
    ]

    for {mode, expected_message} <- cases do
      upstream = start_upstream(mode)
      setup = gateway_setup(upstream, compact?: true)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Websocket.start_codex_session(auth, %{})

      assert {:error, error} =
               Service.execute_websocket_response(
                 auth,
                 compact_payload(setup, nil),
                 RequestOptions.for_websocket(%{codex_session: session}),
                 fn frame -> send(self(), {:unexpected_frame, frame}) end
               )

      assert error.status == 502
      assert error.code == "invalid_compaction_response"
      assert error.message == expected_message
      refute_received {:unexpected_frame, _frame}

      assert [request] =
               Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

      assert request.status == "failed"
      assert request.last_error_code == "invalid_compaction_response"

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.status == "failed"
      assert settlement_count(request.id) == 1
    end
  end

  defp direct_socket(auth, request_id, extra_opts \\ []) do
    CodexResponsesSocket.init(%{
      auth: auth,
      opts:
        Map.merge(
          %{request_id: request_id, client_ip: "127.0.0.1"},
          Map.new(extra_opts)
        )
    })
  end

  defp compact_payload(setup, turn_state, transport \\ :buffered) do
    client_metadata =
      if is_nil(turn_state), do: %{}, else: %{"x-codex-turn-state" => turn_state}

    client_metadata =
      if transport == :sse do
        Map.put(
          client_metadata,
          "x-codex-turn-metadata",
          Jason.encode!(%{"compaction" => %{"implementation" => "responses_compaction_v2"}})
        )
      else
        client_metadata
      end

    Jason.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "synthetic compact input"},
        %{"type" => "compaction_trigger"}
      ],
      "stream" => true,
      "generate" => true,
      "client_metadata" => client_metadata
    })
  end

  defp ordinary_payload(setup, extra \\ %{}) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => "ordinary turn"}],
      "stream" => true,
      "generate" => true
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp invalid_turn_states do
    [
      ["wrong-type"],
      "   ",
      "control\tvalue",
      "non-ascii-\u00e9",
      String.duplicate("a", 4_097)
    ] ++ edge_wrapped_invalid_turn_states()
  end

  defp edge_wrapped_invalid_turn_states do
    [
      "\tvalid",
      "valid\t",
      "\rvalid",
      "valid\r",
      "\nvalid",
      "valid\n",
      "\r\nvalid",
      "valid\r\n",
      "\u00A0valid",
      "valid\u00A0",
      "\u00A0valid\u00A0"
    ]
  end

  defp malformed_compact_payloads(setup) do
    visible = %{"type" => "message", "role" => "user", "content" => "synthetic visible"}
    hidden = %{"type" => "reasoning", "encrypted_content" => "synthetic hidden"}
    trigger = %{"type" => "compaction_trigger"}

    for input <- [
          [visible, trigger, visible],
          [visible, trigger, trigger],
          [hidden, trigger]
        ] do
      Jason.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => input,
        "stream" => true,
        "generate" => true
      })
    end
  end

  defp assert_invalid_turn_state_error(frame) do
    assert %{
             "type" => "error",
             "error" => %{
               "code" => "invalid_request",
               "param" => @turn_state_param
             }
           } = Jason.decode!(frame)

    refute frame =~ "wrong-type"
    refute frame =~ "control"
    refute frame =~ "non-ascii"
  end

  defp assert_no_invalid_turn_state_side_effects(upstream) do
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end

  defp settlement_count(request_id) do
    Repo.aggregate(
      from(entry in LedgerEntry,
        where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
      ),
      :count
    )
  end

  defp header_values(headers, target_name) do
    for {name, value} <- headers, String.downcase(name) == target_name, do: value
  end

  defp receive_socket_message(state) do
    receive do
      message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:push, {:text, frame}, next_state} = result ->
            if StreamProtocol.internal_control_event?(frame) do
              receive_socket_message(next_state)
            else
              result
            end

          {:ok, next_state} ->
            receive_socket_message(next_state)
        end
    after
      @detection_timeout_ms -> flunk("expected websocket frame")
    end
  end

  defp receive_socket_completion(state) do
    receive do
      message ->
        case CodexResponsesSocket.handle_info(message, state) do
          {:ok, next_state} = result ->
            if MapSet.size(Map.get(next_state, :tasks, MapSet.new())) == 0 do
              result
            else
              receive_socket_completion(next_state)
            end

          {:push, _frame, next_state} ->
            receive_socket_completion(next_state)
        end
    after
      @detection_timeout_ms -> flunk("expected websocket completion")
    end
  end
end
