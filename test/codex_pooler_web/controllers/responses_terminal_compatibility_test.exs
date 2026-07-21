defmodule CodexPoolerWeb.ResponsesTerminalCompatibilityTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @terminal_shapes [
    {:done,
     ~s({"type":"response.done","response":{"id":"resp_terminal_done","custom":{"kept":true}}})},
    {:legacy, ~s({ "id" : "resp_terminal_legacy", "custom" : { "kept" : true } })}
  ]

  @failure_shapes [
    {:failure_coded_incomplete,
     %{
       "type" => "response.incomplete",
       "response" => %{
         "id" => "resp_terminal_incomplete",
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "context_length_exceeded"}
       }
     }, "context_length_exceeded"},
    {:coded_error,
     %{
       "type" => "error",
       "error" => %{
         "type" => "invalid_request_error",
         "code" => "context_length_exceeded",
         "message" => "synthetic upstream detail"
       }
     }, "context_length_exceeded"},
    {:failed_without_nested_code,
     %{
       "type" => "response.failed",
       "response" => %{
         "id" => "resp_terminal_failed",
         "status" => "failed",
         "error" => %{"message" => "synthetic upstream detail"}
       }
     }, nil},
    {:typeless_detail, %{"detail" => "synthetic upstream detail"}, "upstream_terminal_failure"}
  ]

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    on_exit(fn ->
      cleanup_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    :ok
  end

  @tag :t9_contract_red
  test "upstream websocket bridge exposes the structured terminal contract" do
    fixture = CompatibilityMatrix.fixture!(:upstream_websocket_bridge)

    assert fixture.fallback == %{
             boundary: "first_downstream_visible_public_event",
             precommit_buffer_event_types: [
               "response.created",
               "response.in_progress",
               "response.queued",
               "codex.rate_limits"
             ],
             unknown_typed_event: :commit,
             legacy_typeless_success: :completed_preserve_raw,
             backend_done_event: :preserve,
             public_http_done_event: :response_completed,
             public_websocket_done_event: :response_completed,
             synthetic_missing_terminal_surfaces: ["public_post_http_sse"],
             target: "same_candidate_same_attempt_http",
             settlements: 1,
             post_visible_upstream_death: "failed_request",
             cache_locality: "heuristic_never_guarantee"
           }

    refute Map.has_key?(fixture.fallback, :internal_events)
  end

  test "backend POST SSE preserves done and legacy decoded payloads", %{conn: conn} do
    for {shape, frame} <- @terminal_shapes do
      setup = http_terminal_setup(frame)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/backend-api/codex/responses", stream_payload(setup, shape))

      assert response.status == 200
      assert [payload] = decoded_sse_payloads(response.resp_body)
      assert payload == Jason.decode!(frame)
    end
  end

  test "public POST SSE normalizes done and legacy success fields", %{conn: conn} do
    for {shape, frame} <- @terminal_shapes do
      setup = http_terminal_setup(frame)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", stream_payload(setup, shape))

      assert response.status == 200

      assert payload =
               Enum.find(
                 decoded_sse_payloads(response.resp_body),
                 &(&1["type"] == "response.completed")
               )

      assert_public_completed(payload, shape)
    end
  end

  test "GET websocket direct chunks preserve backend frames and normalize public fields" do
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)

    for {shape, frame} <- @terminal_shapes do
      assert websocket_terminal("/backend-api/codex/responses", frame, shape) == frame

      "/v1/responses"
      |> websocket_terminal(frame, shape)
      |> Jason.decode!()
      |> assert_public_completed(shape)
    end
  end

  test "GET websocket owner forwarding preserves backend frames and normalizes public fields" do
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    for {shape, frame} <- @terminal_shapes do
      assert websocket_terminal("/backend-api/codex/responses", frame, shape) == frame

      "/v1/responses"
      |> websocket_terminal(frame, shape)
      |> Jason.decode!()
      |> assert_public_completed(shape)
    end
  end

  test "public POST SSE keeps canonical terminal error transformations", %{conn: conn} do
    for {shape, payload, expected_code} <- @failure_shapes, shape != :typeless_detail do
      setup = http_failure_terminal_setup(shape, payload)

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", stream_payload(setup, shape))

      assert response.status == 200

      events = decoded_sse_payloads(response.resp_body)

      assert terminal =
               Enum.find(events, fn event -> event["type"] in ["response.failed", "error"] end),
             "missing canonical POST terminal for #{shape}: #{inspect(events)}"

      assert terminal_error_code(terminal) == post_terminal_error_code(shape, expected_code)
      refute response.resp_body =~ "synthetic upstream detail"
    end
  end

  test "public GET websocket keeps canonical terminal error transformations" do
    for owner_forwarding? <- [false, true],
        {shape, payload, expected_code} <- @failure_shapes do
      Application.put_env(
        :codex_pooler,
        :websocket_owner_forwarding_enabled,
        owner_forwarding?
      )

      terminal =
        "/v1/responses"
        |> websocket_terminal(Jason.encode!(payload), shape)
        |> Jason.decode!()

      assert terminal_error_code(terminal) == expected_code,
             "unexpected websocket terminal for #{shape}: #{inspect(terminal)}"
    end
  end

  defp websocket_terminal_setup(frame) do
    frame
    |> then(&FakeUpstream.websocket_text_frames([&1]))
    |> start_upstream()
    |> gateway_setup()
  end

  defp http_terminal_setup(frame) do
    frame
    |> then(&("data: " <> &1 <> "\n\n"))
    |> then(&FakeUpstream.sse_stream([&1], done: false))
    |> start_upstream()
    |> gateway_setup()
  end

  defp http_failure_terminal_setup(shape, payload) do
    shape
    |> failure_event_name()
    |> then(&FakeUpstream.sse_stream([{&1, payload}], done: false))
    |> start_upstream()
    |> gateway_setup()
  end

  defp failure_event_name(:failure_coded_incomplete), do: "response.incomplete"
  defp failure_event_name(:coded_error), do: "error"
  defp failure_event_name(:failed_without_nested_code), do: "response.failed"
  defp failure_event_name(:typeless_detail), do: "error"

  defp stream_payload(setup, shape) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "synthetic #{shape} terminal compatibility request",
      "stream" => true
    }
  end

  defp websocket_terminal(path, frame, shape) do
    setup = websocket_terminal_setup(frame)
    port = start_public_endpoint!()
    turn_state = "t9-#{shape}-#{System.unique_integer([:positive])}"
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state, path)

    try do
      payload =
        setup
        |> stream_payload(shape)
        |> Map.merge(%{"type" => "response.create", "generate" => true})
        |> Jason.encode!()

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, terminal_frame} = public_websocket_receive_text!(conn, websocket, ref)
      terminal_frame
    after
      Mint.HTTP.close(conn)
    end
  end

  defp decoded_sse_payloads(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/^data: (.+)$/m, block, capture: :all_but_first) do
        ["[DONE]"] -> []
        [data] -> [Jason.decode!(data)]
        _missing -> []
      end
    end)
  end

  defp assert_public_completed(payload, shape) do
    expected_id = if shape == :done, do: "resp_terminal_done", else: "resp_terminal_legacy"

    assert payload["type"] == "response.completed"
    assert payload["response"]["id"] == expected_id
    assert payload["response"]["status"] == "completed"
    assert payload["response"]["custom"] == %{"kept" => true}

    payload
  end

  defp terminal_error_code(payload) do
    get_in(payload, ["error", "code"]) ||
      get_in(payload, ["response", "error", "code"]) ||
      get_in(payload, ["response", "incomplete_details", "reason"])
  end

  defp post_terminal_error_code(:failed_without_nested_code, _websocket_code),
    do: "upstream_error"

  defp post_terminal_error_code(_shape, shared_code), do: shared_code

  defp cleanup_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn session_id ->
        with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(session_id) do
          GenServer.stop(owner_pid, :shutdown, 1_000)
        end
      end)
    end)
  end
end
