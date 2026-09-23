defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ValidationRejectionHealthTest do
  # A provider parameter-validation refusal is the client's error, not the
  # account's: the HTTP path answers the 400 and leaves route health alone,
  # and a native websocket turn refused with the same code must do the same.
  # `invalid_value`, `invalid_type` and `string_above_max_length` used to be
  # missing from the health-neutral codes, so the websocket terminal demoted
  # the assignment and recorded a circuit failure for a request no account
  # could have served (findings#254 row 254-20).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [assert_single_native_turn_terminal!: 2, collect_native_turn_frames!: 1, stop_registered_websocket_owner_sessions: 0, strict_native_request: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Runtime.Finalization.ValidationRejection
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @provider_sentinel "private-ws-validation-health-sentinel"
  @prompt_sentinel "private-ws-validation-health-prompt"
  @param "input[0].content"

  test "every relayable validation code is health-neutral" do
    for code <- ValidationRejection.relayable_codes() do
      assert ErrorCodes.health_neutral_error_code?(code), "#{code} would demote the route on a websocket terminal"
    end
  end

  for code <- ~w(invalid_value invalid_type string_above_max_length unsupported_value) do
    @tag validation_code: code
    test "native HTTP SSE 400 #{code} leaves route health untouched", %{conn: conn, validation_code: code} do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => provider_error(code)}})
          ])
        )

      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true})

      assert response.status == 400
      assert json_response(response, 400) == %{"error" => pooler_error(code)}

      {request, attempt} = sole_rows!(setup)
      assert request.status == "failed"
      assert attempt.transport == "http_sse"
      assert_route_health_untouched!(request)
    end

    for topology <- [:direct, :local_owner] do
      @tag validation_code: code, topology: topology
      test "native websocket #{topology} provider 400 #{code} leaves route health untouched", %{validation_code: code, topology: topology} do
        if topology == :local_owner, do: enable_owner_forwarding!()

        upstream =
          start_upstream(
            FakeUpstream.strict_sequence([
              strict_native_request(1, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "error", "status" => 400, "error" => provider_error(code)})]))
            ])
          )

        setup = gateway_setup(upstream)
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

        {:ok, state} =
          CodexResponsesSocket.init(%{
            auth: auth,
            opts: %{request_id: "ws-validation-health-#{code}-#{topology}", accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}
          })

        try do
          payload =
            CodexPooler.JSON.encode!(%{
              "type" => "response.create",
              "model" => setup.model.exposed_model_id,
              "input" => native_text_input(@prompt_sentinel),
              "stream" => true,
              "generate" => true
            })

          assert {:ok, turn_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          {turn_state, frames} = collect_native_turn_frames!(turn_state)
          # The client receives the wrapped `error` event carrying the error the
          # HTTP answer above relays for the same refusal, never the provider
          # message: the released client reads it as a non-retryable invalid
          # request, as it reads the HTTP 400, where a `response.failed` naming
          # this code is a retryable stream error (findings#254 row 254-31).
          terminal = assert_single_native_turn_terminal!(frames, "error")
          # The socket holds no per-turn input index map, so the param keeps
          # its path but not its index (findings#254 row 254-61).
          assert terminal == %{"type" => "error", "status" => 400, "error" => pooler_error(code, "input[].content")}
          refute CodexPooler.JSON.encode!(frames) =~ @provider_sentinel

          assert :ok = FakeUpstream.verify!(upstream)
          {request, attempt} = sole_rows!(setup)
          assert request.status == "failed"
          assert request.last_error_code == code
          assert attempt.transport == "websocket"

          # The native socket relays the refusal as its canonical
          # `response.failed`; the attempt still records the rejection fields the
          # HTTP path records for the same provider response (findings#254 row
          # 254-30).
          assert Map.take(attempt.response_metadata, ["rejection_error_code", "rejection_error_type", "rejection_error_param"]) == %{
                   "rejection_error_code" => code,
                   "rejection_error_type" => "invalid_request_error",
                   "rejection_error_param" => @param
                 }

          assert_route_health_untouched!(request)
          assert :ok = CodexResponsesSocket.terminate(:closed, turn_state)
        after
          CodexResponsesSocket.terminate(:closed, state)
        end
      end
    end
  end

  # The provider's websocket refusal of an unknown input item id carries no
  # code and no param (254-60, iCoreTech rev 23, where native attempts
  # recorded no rejection field before 254-30). Compact and multi-line frames
  # both record the type and message presence the HTTP path records.
  for topology <- [:direct, :local_owner], pretty <- [false, true] do
    @tag topology: topology, pretty: pretty
    test "native websocket #{topology} codeless provider 400 records its rejection fields (multi-line: #{pretty})", %{topology: topology, pretty: pretty} do
      if topology == :local_owner, do: enable_owner_forwarding!()

      provider_error = %{"type" => "invalid_request_error", "code" => nil, "message" => "Invalid 'input[1].id': '#{@provider_sentinel}'.", "param" => nil}
      frame = %{"type" => "error", "status" => 400, "error" => provider_error}
      text = if pretty, do: Jason.encode!(frame, pretty: true), else: CodexPooler.JSON.encode!(frame)

      upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_text_frames([text]))]))
      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      {:ok, state} =
        CodexResponsesSocket.init(%{
          auth: auth,
          opts: %{request_id: "ws-codeless-rejection-#{topology}-#{pretty}", accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}
        })

      try do
        payload =
          CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true, "generate" => true})

        assert {:ok, turn_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
        {turn_state, frames} = collect_native_turn_frames!(turn_state)
        # The released client retries a `response.failed` whose code it does
        # not classify and then falls back to HTTPS; the wrapped 400 is a final
        # invalid request, as the HTTP 400 of the same refusal is. The error is
        # Pooler-authored from the sanitized type alone (findings#254 row
        # 254-52).
        terminal = assert_single_native_turn_terminal!(frames, "error")

        assert terminal == %{
                 "type" => "error",
                 "status" => 400,
                 "error" => %{"type" => "invalid_request_error", "code" => "invalid_request", "param" => nil, "message" => "upstream rejected the request (invalid_request)"}
               }

        refute CodexPooler.JSON.encode!(frames) =~ @provider_sentinel

        assert :ok = FakeUpstream.verify!(upstream)
        {request, attempt} = sole_rows!(setup)
        assert request.status == "failed"

        assert Map.take(attempt.response_metadata, ["rejection_error_type", "rejection_message_present", "rejection_error_code", "rejection_error_param"]) == %{
                 "rejection_error_type" => "invalid_request_error",
                 "rejection_message_present" => true
               }

        refute inspect(attempt) =~ @provider_sentinel
        assert :ok = CodexResponsesSocket.terminate(:closed, turn_state)
      after
        CodexResponsesSocket.terminate(:closed, state)
      end
    end
  end

  # A provider refusal whose code the released client does not classify from
  # `response.failed` reaches it as the wrapped 400 with a Pooler-authored
  # error: code and param come from the sanitized tokens, the `input[N]` index
  # is dropped (the socket holds no per-turn index map), the provider message
  # never travels (findings#254 row 254-52).
  for topology <- [:direct, :local_owner] do
    @tag topology: topology
    test "native websocket #{topology} unrelayable-code provider 400 reaches the client as the wrapped error", %{topology: topology} do
      if topology == :local_owner, do: enable_owner_forwarding!()

      provider_error = %{"type" => "invalid_request_error", "code" => "invalid_encrypted_content", "message" => "Encrypted content '#{@provider_sentinel}' could not be verified.", "param" => "input[2].encrypted_content"}
      frames = native_refusal_frames!("ws-unrelayable-refusal-#{topology}", %{"type" => "error", "status" => 400, "error" => provider_error})

      assert assert_single_native_turn_terminal!(frames, "error") == %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_encrypted_content",
                 "param" => "input[].encrypted_content",
                 "message" => "upstream rejected parameter input[].encrypted_content (invalid_encrypted_content)"
               }
             }

      refute CodexPooler.JSON.encode!(frames) =~ @provider_sentinel
    end
  end

  # The codes the released client classifies from `response.failed` keep that
  # frame: a wrapped 400 would turn `context_length_exceeded` (which starts a
  # compaction) or a quota/policy code into a plain invalid request.
  for code <- ~w(context_length_exceeded insufficient_quota usage_not_included invalid_prompt cyber_policy bio_policy) do
    @tag classified_code: code
    test "native websocket provider 400 #{code} keeps the response.failed the client classifies", %{classified_code: code} do
      provider_error = %{"type" => "invalid_request_error", "code" => code, "message" => "synthetic #{code}", "param" => nil}
      frames = native_refusal_frames!("ws-classified-refusal-#{code}", %{"type" => "error", "status" => 400, "error" => provider_error})

      terminal = assert_single_native_turn_terminal!(frames, "response.failed")
      assert %{"status" => 400, "response" => %{"status" => "failed", "error" => %{"code" => ^code}}} = terminal
    end
  end

  defp native_refusal_frames!(request_id, frame) do
    upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(frame)]))]))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: request_id, accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}})

    try do
      payload =
        CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input(@prompt_sentinel), "stream" => true, "generate" => true})

      assert {:ok, turn_state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      {turn_state, frames} = collect_native_turn_frames!(turn_state)
      assert :ok = FakeUpstream.verify!(upstream)
      assert {_request, _attempt} = sole_rows!(setup)
      assert :ok = CodexResponsesSocket.terminate(:closed, turn_state)
      frames
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp pooler_error(code, param \\ @param) do
    %{"type" => "invalid_request_error", "code" => code, "param" => param, "message" => "upstream rejected parameter #{param} (#{code})"}
  end

  defp provider_error(code) do
    %{"type" => "invalid_request_error", "code" => code, "message" => "Invalid '#{@param}': '#{@provider_sentinel}'.", "param" => @param}
  end

  defp assert_route_health_untouched!(request) do
    health = %{
      demotion_reason: get_in(request.request_metadata, ["routing", "demotion_reason"]),
      demotions: Repo.all(from(demotion in BridgeDemotion, select: {demotion.reason_code, demotion.status})),
      circuits: Repo.all(from(circuit in RoutingCircuitState, select: {circuit.route_class, circuit.reason_code, circuit.failure_count}))
    }

    assert health == %{demotion_reason: nil, demotions: [], circuits: []}
  end

  defp sole_rows!(setup) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    {request, attempt}
  end

  defp enable_owner_forwarding! do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    on_exit(&stop_registered_websocket_owner_sessions/0)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
  end
end
