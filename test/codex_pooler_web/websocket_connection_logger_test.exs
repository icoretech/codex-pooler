defmodule CodexPoolerWeb.WebsocketConnectionLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPoolerWeb.WebsocketConnectionLogger

  @metadata_keys ~w(
    codex_session_id
    downstream_epoch
    elapsed_ms
    endpoint
    error_code
    handoff_outcome
    owner_instance_id
    phase
    proxy_instance_id
    reconnect_disposition
    reason_class
    reason_code
    request_id
    route_class
    transport
    visible_output
  )

  @forbidden_terms ~w(
    auth.json
    authorization
    bearer
    cookie
    headers
    idempotency
    model
    owner_pid
    payload
    prompt
    raw_turn_id
    response_id
    turn_claim_key
    upstream_body
    websocket_frame
  )

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  describe "pre-request lifecycle events" do
    test "preserves init and terminate phases with bounded allowlisted metadata" do
      long_request_id = String.duplicate("r", 121)
      long_session_id = String.duplicate("s", 121)

      init_log =
        capture_lifecycle_log(fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_init_failed_before_request_reservation(
                     lifecycle_metadata(long_request_id, long_session_id, "init"),
                     :timeout
                   )
        end)

      close_log =
        capture_lifecycle_log(fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_closed_before_request_reservation(
                     lifecycle_metadata(
                       "close/request id",
                       "session/id with spaces",
                       "terminate"
                     ),
                     {:deserializing, :max_frame_size_exceeded}
                   )
        end)

      init_line =
        assert_lifecycle_line!(
          init_log,
          WebsocketConnectionLogger.init_failed_message(),
          ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport)
        )

      close_line =
        assert_lifecycle_line!(
          close_log,
          WebsocketConnectionLogger.closed_message(),
          ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport)
        )

      assert init_line =~ "phase=init"
      assert init_line =~ "request_id=#{String.duplicate("r", 120)}"
      assert init_line =~ "codex_session_id=#{String.duplicate("s", 120)}"
      assert close_line =~ "phase=terminate"
      assert close_line =~ "request_id=close_request_id"
      assert close_line =~ "codex_session_id=session_id_with_spaces"
      assert close_line =~ "reason_class=max_frame_size_exceeded"
    end

    test "keeps fragmented message cap and generic close reasons queryable" do
      assert WebsocketConnectionLogger.reason_class("Received oversize fragmented message") ==
               "max_fragmented_message_size_exceeded"

      assert WebsocketConnectionLogger.reason_class(:closed) == "closed"
    end

    test "characterizes close and native failure event identifiers and fields" do
      close_log =
        capture_lifecycle_log(fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_closed_before_request_reservation(
                     Map.merge(
                       lifecycle_metadata("close-request", "close-session", "terminate"),
                       %{reconnect_disposition: :owner_busy, handoff_outcome: :ready}
                     ),
                     :closed
                   )
        end)

      failure_log =
        capture_lifecycle_log(fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_failed_native_websocket_turn(
                     %{
                       request_id: "failure-request",
                       codex_session_id: "failure-session",
                       error_code: :owner_busy,
                       transport: "websocket",
                       reconnect_disposition: :owner_busy,
                       handoff_outcome: :ready
                     },
                     :owner_busy
                   )
        end)

      close_line =
        assert_lifecycle_line!(
          close_log,
          WebsocketConnectionLogger.closed_message(),
          ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport)
        )

      failure_line =
        assert_lifecycle_line!(
          failure_log,
          WebsocketConnectionLogger.failed_native_websocket_turn_message(),
          ~w(codex_session_id error_code reason_class reason_code request_id transport)
        )

      assert close_line =~ "reason_class=closed"
      assert failure_line =~ "error_code=owner_busy"
      assert failure_line =~ "reason_code=owner_busy"
      refute close_line =~ "reconnect_disposition="
      refute close_line =~ "handoff_outcome="
      refute failure_line =~ "reconnect_disposition="
      refute failure_line =~ "handoff_outcome="
    end

    test "redacts sensitive correlators and drops non-allowlisted keys" do
      sentinel = "SENTINEL_PRIVATE_VALUE"

      log =
        capture_lifecycle_log(fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_closed_before_request_reservation(
                     %{
                       request_id: "request-with-bearer-secret",
                       codex_session_id: "session-with-prompt-secret",
                       endpoint: "/responses?authorization=secret",
                       transport: "websocket",
                       phase: "terminate",
                       prompt: sentinel,
                       headers: [{"cookie", sentinel}],
                       raw_frame: sentinel
                     },
                     {:error, %{prompt: sentinel}}
                   )
        end)

      line =
        assert_lifecycle_line!(
          log,
          WebsocketConnectionLogger.closed_message(),
          ~w(codex_session_id endpoint phase reason_class request_id transport)
        )

      assert line =~ "request_id=redacted"
      assert line =~ "codex_session_id=redacted"
      assert line =~ "endpoint=redacted"
      assert line =~ "reason_class=non_atom_reason"
      refute log =~ sentinel
    end
  end

  describe "native turn failures" do
    test "preserves diagnostic code words while redacting sensitive correlators" do
      for code <- ~w(prompt_parse_failed header_contract_failed payload_shape_failed) do
        log =
          capture_lifecycle_log(
            fn ->
              WebsocketConnectionLogger.log_failed_native_websocket_turn(
                %{
                  request_id: "request-with-prompt-value",
                  codex_session_id: "session-with-header-value",
                  error_code: code,
                  payload: "PRIVATE_DIAGNOSTIC_SENTINEL"
                },
                %{"code" => code, "message" => "PRIVATE_DIAGNOSTIC_SENTINEL"}
              )
            end,
            :warning
          )

        assert log =~ "error_code=#{code}"
        assert log =~ "reason_code=#{code}"
        assert log =~ "reason_class=#{code}"
        assert log =~ "request_id=redacted"
        assert log =~ "codex_session_id=redacted"
        refute log =~ "PRIVATE_DIAGNOSTIC_SENTINEL"
      end
    end

    test "classifies atom and string map codes without logging other map fields" do
      for reason <- [
            %{code: :invalid_transition, details: "PRIVATE_DIAGNOSTIC_SENTINEL"},
            %{"code" => "invalid_transition", "message" => "PRIVATE_DIAGNOSTIC_SENTINEL"}
          ] do
        log =
          capture_lifecycle_log(
            fn ->
              WebsocketConnectionLogger.log_failed_native_websocket_turn(
                %{request_id: "safe-request", error_code: :gateway_reservation_failed},
                reason
              )
            end,
            :warning
          )

        assert log =~ "reason_class=invalid_transition"
        assert log =~ "reason_code=invalid_transition"
        refute log =~ "PRIVATE_DIAGNOSTIC_SENTINEL"
      end
    end

    test "renders known map, atom, and tuple codes without a fabricated phase" do
      cases = [
        {%{code: :owner_unavailable}, "owner_unavailable"},
        {:owner_drained, "owner_drained"},
        {{:owner_forward_timeout, :details}, "owner_forward_timeout"}
      ]

      Enum.each(cases, fn {reason, expected_code} ->
        log =
          capture_lifecycle_log(
            fn ->
              assert :ok =
                       WebsocketConnectionLogger.log_failed_native_websocket_turn(
                         %{
                           request_id: "request/#{expected_code}",
                           codex_session_id: "session/#{expected_code}",
                           error_code: expected_code,
                           transport: "websocket",
                           visible_output: :before_visible_output
                         },
                         reason
                       )
            end,
            WebsocketConnectionLogger.failed_native_websocket_turn_level(expected_code)
          )

        line =
          assert_lifecycle_line!(
            log,
            WebsocketConnectionLogger.failed_native_websocket_turn_message(),
            ~w(codex_session_id error_code reason_class reason_code request_id transport visible_output)
          )

        assert line =~ "request_id=request_#{expected_code}"
        assert line =~ "codex_session_id=session_#{expected_code}"
        assert line =~ "error_code=#{expected_code}"
        assert line =~ "reason_code=#{expected_code}"
        refute line =~ "phase="
      end)
    end

    test "relays clean unknown direct and map codes in cleartext" do
      unknown_direct = "synthetic_unknown_direct_code"
      unknown_map = "synthetic_unknown_map_code"

      for reason <- [unknown_direct, %{"code" => unknown_map}] do
        raw_code = if is_binary(reason), do: reason, else: reason["code"]
        assert DiagnosticTaxonomy.identifier(raw_code) == raw_code

        log =
          capture_lifecycle_log(
            fn ->
              assert :ok =
                       WebsocketConnectionLogger.log_failed_native_websocket_turn(
                         %{request_id: "safe-request", error_code: raw_code},
                         reason
                       )
            end,
            :warning
          )

        line =
          assert_lifecycle_line!(
            log,
            WebsocketConnectionLogger.failed_native_websocket_turn_message(),
            ~w(error_code reason_class reason_code request_id)
          )

        assert line =~ "error_code=#{raw_code}"
        assert line =~ "reason_code=#{raw_code}"
      end
    end

    test "fingerprints unclean unknown codes without exposing the raw value" do
      raw_code = "synthetic unknown code with spaces"
      fingerprint = DiagnosticTaxonomy.identifier(raw_code)
      assert fingerprint =~ ~r/^sha256_[0-9a-f]{12}$/

      log =
        capture_lifecycle_log(
          fn ->
            assert :ok =
                     WebsocketConnectionLogger.log_failed_native_websocket_turn(
                       %{request_id: "safe-request", error_code: raw_code},
                       %{"code" => raw_code}
                     )
          end,
          :warning
        )

      line =
        assert_lifecycle_line!(
          log,
          WebsocketConnectionLogger.failed_native_websocket_turn_message(),
          ~w(error_code reason_class reason_code request_id)
        )

      assert line =~ "error_code=#{fingerprint}"
      assert line =~ "reason_code=#{fingerprint}"
      refute log =~ raw_code
    end

    test "fingerprints control invalid UTF-8 and overlong diagnostic codes" do
      for raw_code <- ["prompt\nheader", <<255, 0>>, String.duplicate("payload", 20)] do
        fingerprint = DiagnosticTaxonomy.identifier(raw_code)

        log =
          capture_lifecycle_log(
            fn ->
              WebsocketConnectionLogger.log_failed_native_websocket_turn(
                %{request_id: "safe-request", error_code: raw_code},
                %{code: raw_code}
              )
            end,
            :warning
          )

        assert fingerprint =~ ~r/^sha256_[0-9a-f]{12}$/
        assert log =~ "error_code=#{fingerprint}"
        assert log =~ "reason_code=#{fingerprint}"
        assert log =~ "reason_class=#{fingerprint}"
        assert String.valid?(log)
        refute log =~ raw_code
      end
    end

    test "does not invent a reason code for a non-code map" do
      log =
        capture_lifecycle_log(
          fn ->
            assert :ok =
                     WebsocketConnectionLogger.log_failed_native_websocket_turn(
                       %{
                         request_id: "safe-request",
                         error_code: :websocket_request_failed,
                         reason_code: :owner_busy
                       },
                       %{reason: :owner_busy}
                     )
          end,
          :warning
        )

      line =
        assert_lifecycle_line!(
          log,
          WebsocketConnectionLogger.failed_native_websocket_turn_message(),
          ~w(error_code reason_class request_id)
        )

      assert line =~ "error_code=websocket_request_failed"
      refute line =~ "reason_code="
    end

    test "keeps exact severity for expected lifecycle outcomes" do
      assert :info ==
               WebsocketConnectionLogger.failed_native_websocket_turn_level("client_disconnected")

      assert :info == WebsocketConnectionLogger.failed_native_websocket_turn_level(:owner_drained)

      assert :warning ==
               WebsocketConnectionLogger.failed_native_websocket_turn_level(
                 "upstream_request_failed"
               )

      warning_log =
        capture_log([level: :warning], fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_failed_native_websocket_turn(
                     %{request_id: "safe-request", error_code: "client_disconnected"},
                     :client_disconnected
                   )
        end)

      assert warning_log == ""
    end
  end

  describe "reconnect lifecycle events" do
    test "emits every fixed reconnect disposition with safe correlators only" do
      sentinel = "TASK2_PRIVATE_RECONNECT_SENTINEL"

      for disposition <- ~w(same_turn_replay replacement_handoff identity_rejected owner_busy) do
        log =
          capture_lifecycle_log(fn ->
            assert :ok =
                     WebsocketConnectionLogger.log_reconnect_disposition(
                       reconnect_metadata(sentinel),
                       disposition
                     )
          end)

        line =
          assert_lifecycle_line!(
            log,
            WebsocketConnectionLogger.reconnect_disposition_message(),
            ~w(
              codex_session_id
              downstream_epoch
              elapsed_ms
              owner_instance_id
              phase
              proxy_instance_id
              reconnect_disposition
              request_id
            )
          )

        assert line =~ "reconnect_disposition=#{disposition}"
        refute line =~ "handoff_outcome="
        refute log =~ sentinel
      end
    end

    test "emits every fixed terminal handoff outcome with safe correlators only" do
      sentinel = "TASK2_PRIVATE_OUTCOME_SENTINEL"

      for outcome <- ~w(ready timeout owner_drained socket_closed submission_expired) do
        log =
          capture_lifecycle_log(fn ->
            assert :ok =
                     WebsocketConnectionLogger.log_handoff_outcome(
                       reconnect_metadata(sentinel),
                       outcome
                     )
          end)

        line =
          assert_lifecycle_line!(
            log,
            WebsocketConnectionLogger.handoff_outcome_message(),
            ~w(
              codex_session_id
              downstream_epoch
              elapsed_ms
              handoff_outcome
              owner_instance_id
              phase
              proxy_instance_id
              request_id
            )
          )

        assert line =~ "handoff_outcome=#{outcome}"
        refute line =~ "reconnect_disposition="
        refute log =~ sentinel
      end
    end

    test "emits one classification and one terminal outcome for a synthetic handoff" do
      log =
        capture_lifecycle_log(fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_reconnect_disposition(
                     reconnect_metadata("TASK2_PRIVATE_HANDOFF_SENTINEL"),
                     :replacement_handoff
                   )

          assert :ok =
                   WebsocketConnectionLogger.log_handoff_outcome(
                     reconnect_metadata("TASK2_PRIVATE_HANDOFF_SENTINEL"),
                     :ready
                   )
        end)

      assert 1 == event_count(log, WebsocketConnectionLogger.reconnect_disposition_message())
      assert 1 == event_count(log, WebsocketConnectionLogger.handoff_outcome_message())
      refute log =~ "TASK2_PRIVATE_HANDOFF_SENTINEL"
    end

    test "omits unknown reconnect enums and arbitrary metadata" do
      sentinel = "TASK2_PRIVATE_UNKNOWN_SENTINEL"

      log =
        capture_lifecycle_log(fn ->
          assert :ok =
                   WebsocketConnectionLogger.log_reconnect_disposition(
                     reconnect_metadata(sentinel),
                     "unbounded-private-disposition"
                   )

          assert :ok =
                   WebsocketConnectionLogger.log_handoff_outcome(
                     reconnect_metadata(sentinel),
                     :unbounded_private_outcome
                   )
        end)

      assert log == ""
      refute log =~ sentinel
    end
  end

  defp lifecycle_metadata(request_id, session_id, phase) do
    %{
      request_id: request_id,
      endpoint: "/backend-api/codex/responses",
      transport: "websocket",
      route_class: "proxy_websocket",
      phase: phase,
      elapsed_ms: 17,
      codex_session_id: session_id,
      ignored_key: "not-logged"
    }
  end

  defp reconnect_metadata(sentinel) do
    %{
      request_id: "request/reconnect",
      codex_session_id: "session/reconnect",
      owner_instance_id: "owner/reconnect",
      proxy_instance_id: "proxy/reconnect",
      downstream_epoch: 7,
      phase: "handoff",
      elapsed_ms: 19,
      raw_turn_id: sentinel,
      turn_claim_key: sentinel,
      prompt: sentinel,
      request_body: sentinel,
      websocket_frame: sentinel,
      model: sentinel,
      response_id: sentinel,
      idempotency_key: sentinel,
      owner_pid: self(),
      arbitrary_metadata: sentinel
    }
  end

  defp capture_lifecycle_log(fun, level \\ :info) do
    capture_log(
      [
        level: level,
        format: "$metadata$message\n",
        metadata: @metadata_keys,
        colors: [enabled: false]
      ],
      fun
    )
  end

  defp assert_lifecycle_line!(logs, message, required_keys) do
    assert [line] =
             logs
             |> String.split("\n", trim: true)
             |> Enum.filter(&String.contains?(&1, message))

    metadata_keys =
      line
      |> String.replace_prefix(message, "")
      |> String.trim_leading()
      |> String.split(" ", trim: true)
      |> Enum.map(fn token -> token |> String.split("=", parts: 2) |> hd() end)

    assert Enum.all?(metadata_keys, &(&1 in @metadata_keys))
    assert Enum.all?(required_keys, &(&1 in metadata_keys))
    refute "ignored_key" in metadata_keys

    downcased_logs = String.downcase(logs)

    for forbidden_term <- @forbidden_terms do
      refute downcased_logs =~ forbidden_term
    end

    line
  end

  defp event_count(logs, message) do
    logs
    |> String.split("\n", trim: true)
    |> Enum.count(&String.contains?(&1, message))
  end
end
