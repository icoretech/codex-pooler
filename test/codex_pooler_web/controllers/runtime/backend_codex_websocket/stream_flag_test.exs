defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.StreamFlagTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Repo

  # Detection budget for one finalized turn, well above the scenario itself.
  @finalization_detection_timeout_ms 15_000
  @max_turn_frames 20
  @terminal_types ["response.completed", "response.failed", "response.incomplete", "error"]

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  for topology <- [:direct, :local_owner] do
    @tag topology: topology
    test "a native response.create without stream uses the upstream websocket on a #{topology} socket",
         %{topology: topology} do
      Application.put_env(
        :codex_pooler,
        :websocket_owner_forwarding_enabled,
        topology == :local_owner
      )

      response_id = "resp_streamless_#{topology}"
      upstream = streamless_native_upstream(response_id)
      setup = gateway_setup(upstream)
      assert :ok = Events.subscribe_pool(setup.pool)
      port = start_public_endpoint!()
      turn_state = "ws-streamless-#{topology}-#{System.unique_integer([:positive])}"
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

      try do
        payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("streamless native prompt sentinel")
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, _websocket, frames} = receive_turn_frames!(conn, websocket, ref)

        assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} =
                 List.last(frames)

        assert_receive {Events,
                        %{
                          reason: "request_finalized",
                          payload: %{"request_id" => request_id, "status" => "succeeded"}
                        }},
                       @finalization_detection_timeout_ms

        request = Repo.get!(Request, request_id)
        assert request.transport == "websocket"
        assert request.status == "succeeded"

        assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
        assert attempt.status == "succeeded"
        assert attempt.response_metadata["upstream_transport"] == "websocket"
        assert is_map(attempt.response_metadata["upstream_websocket_connection"])

        assert [captured] = FakeUpstream.requests(upstream)
        assert captured.method == "WEBSOCKET"
        refute Map.has_key?(captured.json, "stream")
        :ok = FakeUpstream.verify!(upstream)

        if topology == :local_owner do
          assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
          assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
          assert is_pid(owner_pid)
        end

        refute inspect({request.request_metadata, attempt.response_metadata}) =~
                 "streamless native prompt sentinel"

        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  test "a native response.create with stream false is rejected locally before any work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    turn_state = "ws-stream-false-#{System.unique_integer([:positive])}"
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("stream false prompt sentinel"),
          "stream" => false
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frames} = receive_turn_frames!(conn, websocket, ref)

      assert [
               %{
                 "type" => "error",
                 "status" => 400,
                 "error" => %{
                   "type" => "invalid_request_error",
                   "code" => "invalid_request",
                   "param" => "stream"
                 }
               }
             ] = frames

      refute inspect(frames) =~ "stream false prompt sentinel"
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "a websocket-transport turn without a websocket upstream fails closed before reservation" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch_guard"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    opts =
      RequestOptions.for_websocket(%{
        request_id: "ws-stream-flag-guard-#{System.unique_integer([:positive])}"
      })

    raw_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("guard prompt sentinel"),
        "stream" => true
      })

    assert {:ok, prepared} =
             Service.prepare_websocket_response(raw_payload, opts, fn frame ->
               send(parent, {:guard_frame, frame})
             end)

    assert prepared.request_options.transport.transport == "websocket"
    assert is_function(prepared.request_options.transport.websocket_writer, 1)

    # Force the would-be-HTTP condition: a websocket turn with no writer and no
    # connection-bound compaction collector.
    prepared = %{
      prepared
      | request_options:
          RequestOptions.put_transport(prepared.request_options, websocket_writer: nil)
    }

    assert {:error, %{status: 500, code: "websocket_transport_required"} = reason} =
             Service.execute_prepared_websocket_response(auth, prepared)

    assert %{
             "type" => "error",
             "status" => 500,
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "websocket_transport_required"
             }
           } = Adapter.websocket_error(reason)

    refute_received {:guard_frame, _frame}
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    refute inspect(reason) =~ "guard prompt sentinel"
  end

  for stream_flag <- [:omitted, true] do
    @tag stream_flag: stream_flag
    test "a native response.create with stream #{stream_flag} on a non-streaming model is rejected locally",
         %{stream_flag: stream_flag} do
      upstream =
        start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch_streaming"}))

      setup = gateway_setup(upstream)

      model =
        setup.model |> Ecto.Changeset.change(supports_streaming: false) |> Repo.update!()

      port = start_public_endpoint!()
      turn_state = "ws-non-streaming-#{stream_flag}-#{System.unique_integer([:positive])}"
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

      try do
        payload =
          %{
            "type" => "response.create",
            "model" => model.exposed_model_id,
            "input" => native_text_input("non-streaming model prompt sentinel")
          }
          |> then(fn payload ->
            if stream_flag == true, do: Map.put(payload, "stream", true), else: payload
          end)
          |> CodexPooler.JSON.encode!()

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
        {conn, _websocket, frames} = receive_turn_frames!(conn, websocket, ref)

        assert [
                 %{
                   "type" => "error",
                   "status" => 400,
                   "error" => %{"code" => "unsupported_model_capability", "param" => "stream"}
                 }
               ] = frames

        # Both flags meet the same pre-dispatch capability rejection: one
        # rejected request row, no attempt, and no upstream work.
        assert FakeUpstream.count(upstream) == 0
        assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
        assert request.last_error_code == "unsupported_model_capability"
        assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

        conn
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp streamless_native_upstream(response_id) do
    start_upstream(
      # provenance: observed local dev Pooler repro (native response.create frame without stream, requests 72ba8d90 and 6505a815); provider reply frames are synthetic
      FakeUpstream.strict_sequence([
        FakeUpstream.expect_request(
          method: "WEBSOCKET",
          path: "/backend-api/codex/responses",
          websocket_connection_ordinal: 1,
          json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["stream"]],
          respond:
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "response.created",
                "response" => %{"id" => response_id, "status" => "in_progress"}
              }),
              CodexPooler.JSON.encode!(%{
                "type" => "response.completed",
                "response" => %{
                  "id" => response_id,
                  "status" => "completed",
                  "output" => [],
                  "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
                }
              })
            ])
        )
      ])
    )
  end

  # Collects one turn's frames through its terminal. A typeless frame fails at
  # once: it is the non-terminal HTTP failure body that left clients waiting.
  defp receive_turn_frames!(conn, websocket, ref, frames \\ []) do
    if length(frames) >= @max_turn_frames, do: flunk("websocket turn exceeded frame budget")

    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => "codex.response.metadata"} ->
        receive_turn_frames!(conn, websocket, ref, frames)

      %{"type" => type} = decoded when type in @terminal_types ->
        {conn, websocket, Enum.reverse([decoded | frames])}

      %{"type" => type} = decoded when is_binary(type) ->
        receive_turn_frames!(conn, websocket, ref, [decoded | frames])

      decoded ->
        flunk("typeless websocket frame keys=#{inspect(decoded |> Map.keys() |> Enum.sort())}")
    end
  end
end
