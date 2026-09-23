defmodule CodexPoolerWeb.V1.ResponsesBackendInternalEventTest do
  # The Codex backend's websocket transport sends events outside the public
  # Responses stream vocabulary, such as `responsesapi.websocket_timing`
  # between the last output item and the terminal. The public `/v1/responses`
  # SSE surface relays only the public vocabulary (`response.*` plus the
  # `error` terminal and `keepalive`): openai-node's `responses.stream()`
  # throws `Unhandled response stream event` on any other type, which broke
  # every successful stream bridged over the upstream websocket
  # (findings#225, 225-97). Unknown `response.*` events stay relayed so new
  # public event types keep working.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.FakeUpstream

  @response_id "resp_backend_internal_event_fixture"
  @marker "synthetic internal event marker"

  test "the HTTP SSE upstream path relays no backend-internal event and keeps the sequence contiguous" do
    upstream = start_upstream(FakeUpstream.sse_stream(upstream_events()))
    setup = gateway_setup(upstream)

    response = build_conn() |> auth(setup) |> post("/v1/responses", stream_payload(setup))

    assert response.status == 200
    assert_public_stream!(response.resp_body)
    assert FakeUpstream.websocket_connection_count(upstream) == 0
  end

  test "the websocket-bridged path relays no backend-internal event and keeps the sequence contiguous" do
    enable_owner_forwarding!()

    upstream = start_upstream(FakeUpstream.sse_stream(upstream_events()))
    setup = gateway_setup(upstream)

    response =
      build_conn()
      |> auth(setup)
      |> put_req_header("x-session-id", "internal-event-session-#{System.unique_integer([:positive])}")
      |> post("/v1/responses", stream_payload(setup))

    assert response.status == 200
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert_public_stream!(response.resp_body)
  end

  defp assert_public_stream!(body) do
    events = event_payloads(body)

    assert Enum.map(events, & &1["type"]) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.output_text.delta",
             "response.output_text.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.future_public_event",
             "response.completed"
           ]

    assert Enum.map(events, & &1["sequence_number"]) == Enum.to_list(0..(length(events) - 1))
    refute body =~ "responsesapi."
    refute body =~ "codex.rate_limits"
    refute body =~ "timing_metrics"
  end

  defp upstream_events do
    item = %{"id" => "msg_internal_event", "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}
    part = %{"type" => "output_text", "text" => "", "annotations" => []}
    done_part = %{part | "text" => @marker}
    done_item = %{item | "status" => "completed", "content" => [done_part]}
    address = %{"item_id" => "msg_internal_event", "output_index" => 0, "content_index" => 0}

    [
      {"response.created", %{"type" => "response.created", "response" => response_body("in_progress", [])}},
      {"codex.rate_limits", %{"type" => "codex.rate_limits", "rate_limits" => %{}}},
      {"response.output_item.added", %{"type" => "response.output_item.added", "output_index" => 0, "item" => item}},
      {"response.content_part.added", Map.merge(address, %{"type" => "response.content_part.added", "part" => part})},
      {"response.output_text.delta", Map.merge(address, %{"type" => "response.output_text.delta", "delta" => @marker})},
      {"response.output_text.done", Map.merge(address, %{"type" => "response.output_text.done", "text" => @marker})},
      {"response.content_part.done", Map.merge(address, %{"type" => "response.content_part.done", "part" => done_part})},
      {"response.output_item.done", %{"type" => "response.output_item.done", "output_index" => 0, "item" => done_item}},
      {"responsesapi.websocket_timing", %{"type" => "responsesapi.websocket_timing", "timing_metrics" => %{"engine_service_total_ms" => 457, "engine_service_ttft_total_ms" => 233}}},
      {"response.future_public_event", %{"type" => "response.future_public_event"}},
      {"response.completed", %{"type" => "response.completed", "response" => response_body("completed", [done_item])}}
    ]
  end

  defp response_body(status, output) do
    %{
      "id" => @response_id,
      "object" => "response",
      "created_at" => 1_790_000_000,
      "model" => "provider-gpt-test-model",
      "status" => status,
      "output" => output,
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
    }
  end

  defp stream_payload(setup), do: %{"model" => setup.model.exposed_model_id, "input" => "synthetic internal event turn", "stream" => true}

  defp event_payloads(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      with [_line, data] <- Regex.run(~r/^data: (.+)$/m, block),
           {:ok, %{"type" => _type} = decoded} <- CodexPooler.JSON.decode(data) do
        [decoded]
      else
        _no_event -> []
      end
    end)
  end

  defp enable_owner_forwarding! do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end
end
