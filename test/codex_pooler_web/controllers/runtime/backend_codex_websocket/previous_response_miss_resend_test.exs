defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.PreviousResponseMissResendTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo

  # Detection budget for a settlement the test only observes.
  @settlement_detection_timeout_ms 15_000

  @answer %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

  # The Codex backend's websocket refusal of an anchor the connection cannot
  # resolve (a connection that did not produce the response): a codeless 400
  # `invalid_request_error` (findings#232 row 232-277, live probe 2026-09-23).
  @provider_refusal %{"type" => "error", "status" => 400, "error" => %{"type" => "invalid_request_error", "message" => "Invalid `previous_response_id`."}}

  # The refusal reaches the native client as the `previous_response_not_found`
  # event the Pooler's own connection-bound guard sends (before, as the generic
  # retryable `response.failed` `stream_incomplete`), the attempt keeps the
  # provider's refusal, and the client's full resend of the same turn, without
  # the anchor, is served on the websocket (findings#232 row 232-278). With
  # owner forwarding off the released client met `409 duplicate_turn` on every
  # resend and finished the turn over HTTPS. Frames carry the released client's
  # turn metadata, so the resend is judged on its turn claim.
  for forwarding? <- [false, true] do
    test "the provider's codeless anchor refusal reaches the native client as previous_response_not_found and the full resend completes (owner forwarding #{forwarding?})" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(forwarding?))

      first_input = native_text_input("anchor")
      next_input = native_text_input("next")

      upstream =
        start_upstream(
          # The anchored delta is refused as the provider refuses an anchor its
          # connection did not produce; the client's full resend completes.
          # provenance: observed findings#232 row 232-277 (provider refusal frame, live probe 2026-09-23)
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
              respond: completed_response_frames("resp_ws_invalid_anchor_opener", [@answer], 2, 1)
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => "resp_ws_invalid_anchor_opener"}],
              respond: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(@provider_refusal)])
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
              respond: completed_response_frames("resp_ws_invalid_anchor_resend", [], 4, 3)
            )
          ])
        )

      setup = gateway_setup(upstream)
      assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
      port = start_public_endpoint!()
      thread = "ws-invalid-anchor-#{System.unique_integer([:positive])}"
      {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
      frame = released_client_frame(setup, thread)
      second_turn_id = Ecto.UUID.generate()

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame.(first_input, Ecto.UUID.generate(), %{}))
        {conn, websocket, opener_terminal} = receive_until_terminal(conn, websocket, ref)
        assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_invalid_anchor_opener"}} = opener_terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @settlement_detection_timeout_ms

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame.(next_input, second_turn_id, %{"previous_response_id" => "resp_ws_invalid_anchor_opener"}))
        {conn, websocket, refusal_frame} = public_websocket_receive_text!(conn, websocket, ref)
        assert CodexPooler.JSON.decode!(refusal_frame) == native_previous_response_retry_event()
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @settlement_detection_timeout_ms

        # The Pooler dispatches nothing again: the anchored delta reached the
        # upstream once.
        assert [_opener, _anchored] = FakeUpstream.requests(upstream)

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame.(first_input ++ [@answer] ++ next_input, second_turn_id, %{}))
        {conn, _websocket, resend_terminal} = receive_until_terminal(conn, websocket, ref)
        assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_invalid_anchor_resend"}} = resend_terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @settlement_detection_timeout_ms

        assert [_opener, _anchored, resend_request] = FakeUpstream.requests(upstream)
        assert resend_request.json["input"] == first_input ++ [@answer] ++ next_input

        assert [_opener_row, refused, resend] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))
        assert {refused.status, refused.last_error_code, resend.status} == {"failed", "stream_incomplete", "succeeded"}
        assert resend.request_metadata["client_resend"]["predecessor_request_id"] == refused.id
        assert [refused_attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^refused.id))

        # The attempt keeps the provider's refusal: its fixed message class and
        # no code, since the provider sent none.
        assert %{
                 "upstream_error_code" => "previous_response_not_found",
                 "rejection_error_type" => "invalid_request_error",
                 "rejection_message_class" => "invalid_previous_response_id",
                 "rejection_upstream_status" => 400
               } = refused_attempt.response_metadata

        refute Map.has_key?(refused_attempt.response_metadata, "rejection_error_code")
        assert Repo.all(from(demotion in BridgeDemotion)) == []
        assert Repo.all(from(circuit in RoutingCircuitState)) == []
        refute inspect({refused.request_metadata, refused_attempt.response_metadata}) =~ "resp_ws_invalid_anchor_opener"
        assert :ok = FakeUpstream.verify!(upstream)
        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  # The Pooler's own connection-bound guard (here a Full-to-Lite flip under the
  # anchor, findings#232 row 232-210) sends the same retry event, and the full
  # resend of that turn met the same `409 duplicate_turn` on its turn claim
  # (row 232-278).
  for forwarding? <- [false, true] do
    test "the full resend after the connection-bound guard's refusal is served on the websocket (owner forwarding #{forwarding?})" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(forwarding?))

      tools = [%{"type" => "function", "name" => "sample_lookup", "parameters" => %{"type" => "object", "properties" => %{}, "required" => []}}]
      first_input = native_text_input("anchor")
      next_input = native_text_input("next")

      upstream =
        start_upstream(
          # The anchored Lite delta is refused before it is sent; the full
          # resend opens a Lite context on the same connection.
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create", "tools.0.name" => "sample_lookup"}, forbidden: ["previous_response_id"]],
              respond: completed_response_frames("resp_ws_guard_anchor_opener", [@answer], 2, 1)
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "additional_tools"}, forbidden: ["previous_response_id"]],
              respond: completed_response_frames("resp_ws_guard_anchor_resend", [], 4, 3)
            )
          ])
        )

      setup = gateway_setup(upstream)
      scope = model_serving_scope()
      revision = set_model_serving_mode!(scope, setup, "full")
      assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
      port = start_public_endpoint!()
      thread = "ws-guard-anchor-#{System.unique_integer([:positive])}"
      {conn, websocket, ref} = public_websocket_connect!(port, setup, thread)
      base = released_client_frame(setup, thread)
      frame = fn input, turn_id, extra -> base.(input, turn_id, Map.merge(%{"instructions" => "synthetic base instructions", "tools" => tools}, extra)) end
      second_turn_id = Ecto.UUID.generate()

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame.(first_input, Ecto.UUID.generate(), %{}))
        {conn, websocket, opener_terminal} = receive_until_terminal(conn, websocket, ref)
        assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_guard_anchor_opener"}} = opener_terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @settlement_detection_timeout_ms

        _revision = set_model_serving_mode!(scope, setup, "lite", revision)

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame.(next_input, second_turn_id, %{"previous_response_id" => "resp_ws_guard_anchor_opener"}))
        {conn, websocket, refusal_frame} = public_websocket_receive_text!(conn, websocket, ref)
        assert CodexPooler.JSON.decode!(refusal_frame) == native_previous_response_retry_event()
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @settlement_detection_timeout_ms
        assert [_opener] = FakeUpstream.requests(upstream)

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame.(first_input ++ [@answer] ++ next_input, second_turn_id, %{}))
        {conn, _websocket, resend_terminal} = receive_until_terminal(conn, websocket, ref)
        assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_guard_anchor_resend"}} = resend_terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @settlement_detection_timeout_ms

        assert [_opener_row, refused, resend] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))
        assert {refused.status, resend.status} == {"failed", "succeeded"}
        assert resend.request_metadata["client_resend"]["predecessor_request_id"] == refused.id
        assert :ok = FakeUpstream.verify!(upstream)
        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  # A `response.create` shaped like the released client's: its turn metadata
  # names the thread and the turn, so a resend of the same turn carries the
  # same turn id.
  defp released_client_frame(setup, thread) do
    fn input, turn_id, extra ->
      metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => turn_id}

      %{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => input,
        "stream" => true,
        "generate" => true,
        "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", CodexPooler.JSON.encode!(Map.put(metadata, "request_kind", "turn")))
      }
      |> Map.merge(extra)
      |> CodexPooler.JSON.encode!()
    end
  end

  defp completed_response_frames(response_id, output, input_tokens, output_tokens) do
    FakeUpstream.websocket_text_frames(
      Enum.map(output, &CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => &1})) ++
        [
          CodexPooler.JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => %{"input_tokens" => input_tokens, "output_tokens" => output_tokens, "total_tokens" => input_tokens + output_tokens}}
          })
        ]
    )
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_until_terminal(conn, websocket, ref)
    end
  end
end
