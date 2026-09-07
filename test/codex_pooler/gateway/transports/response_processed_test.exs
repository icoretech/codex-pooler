defmodule CodexPooler.Gateway.Transports.Websocket.ResponseProcessedTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.ResponseProcessed
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request, as: WireRequest

  @endpoint "/backend-api/codex/responses"

  setup do
    %{pool: pool, api_key: key} = active_api_key_fixture()
    %{auth: %{pool: pool, api_key: key, key_prefix: key.key_prefix}}
  end

  test "missing response id is rejected before accounting", %{auth: auth} do
    assert {:error, %{status: 400, code: "invalid_request", param: nil}} =
             ResponseProcessed.handle(auth, %{"type" => "response.processed"}, options())

    assert Repo.aggregate(Request, :count) == 0
  end

  test "missing or disconnected upstream sessions cannot record a successful ack", %{auth: auth} do
    session = start_supervised!(UpstreamWebsocketSession)

    for opts <- [options(), options(%{upstream_websocket_session: session})] do
      assert {:error, %{status: 502, code: "upstream_websocket_forward_failed"}} =
               ResponseProcessed.handle_prepared(auth, payload(), opts)
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  test "successful forwarding records metadata only and keeps session correlation", %{auth: auth} do
    {session, upstream} = connected_session()
    codex_session = %CodexSession{id: Ecto.UUID.generate(), session_key: "session-processed"}

    opts =
      options(%{
        upstream_websocket_session: session,
        codex_session: codex_session,
        request_id: "server-request",
        client_ip: "192.0.2.1",
        user_agent: "sample-client",
        request_bytes: 123
      })

    frame = Map.put(payload(), "request_id", "client-request")
    assert {:ok, %{websocket_messages: []}} = ResponseProcessed.handle(auth, frame, opts)
    request = Repo.one!(Request)
    assert request.correlation_id == "client-request"
    assert request.endpoint == @endpoint
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.usage_status == "not_applicable"
    assert request.response_status_code == 200
    assert request.client_ip == "192.0.2.1"
    assert request.user_agent == "sample-client"
    assert request.request_metadata["response_processed"]
    assert request.request_metadata["requested_stream"] == false
    assert request.request_metadata["request_bytes"] == byte_size(CodexPooler.JSON.encode!(frame))
    assert request.request_metadata["codex_session_id"] == codex_session.id
    assert request.request_metadata["codex_session_key"] == codex_session.session_key
    refute Map.has_key?(request.request_metadata, "response_id")
    refute Map.has_key?(request.request_metadata, "websocket_owner_forwarding")

    # Observe the server handling the ack; ack frames do not invoke the client's turn writer.
    assert_receive {:fake_upstream_chunk_sent, 1}, 15_000
    assert List.last(FakeUpstream.requests(upstream)).json == payload()
  end

  test "turn id takes precedence over client and server request ids", %{auth: auth} do
    {session, _upstream} = connected_session()
    frame = Map.merge(payload(), %{"turn_id" => "turn-processed", "request_id" => "client"})

    assert {:ok, _} =
             ResponseProcessed.handle_prepared(
               auth,
               frame,
               options(%{upstream_websocket_session: session, request_id: "server"})
             )

    assert Repo.one!(Request).correlation_id == "turn-processed"
  end

  test "missing client correlation uses server id or generates an id", %{auth: auth} do
    {session, _upstream} = connected_session()

    for request_id <- ["server-processed", nil] do
      assert {:ok, _} =
               ResponseProcessed.handle_prepared(
                 auth,
                 payload(),
                 options(%{upstream_websocket_session: session, request_id: request_id})
               )
    end

    ids = Repo.all(from request in Request, select: request.correlation_id)
    assert "server-processed" in ids
    assert {:ok, _} = Ecto.UUID.cast(Enum.find(ids, &(&1 != "server-processed")))
  end

  test "accounting rejection after forwarding is surfaced without a success row" do
    {session, _upstream} = connected_session()

    assert {:error, %{status: 500, code: "gateway_accounting_failed", accounting_error: reason}} =
             ResponseProcessed.handle_prepared(
               %{key_prefix: "synthetic"},
               payload(),
               options(%{upstream_websocket_session: session})
             )

    assert is_binary(reason)
    assert Repo.aggregate(Request, :count) == 0
  end

  defp options(attrs \\ %{}), do: RequestOptions.build(attrs, @endpoint, %{})
  defp payload, do: %{"type" => "response.processed", "response_id" => "resp_sample_processed"}

  defp connected_session do
    observer = self()
    events = [%{"type" => "response.completed", "response" => %{"id" => "resp_sample_processed"}}]

    processed_mode =
      FakeUpstream.barrier_sse_stream(events,
        notify: observer,
        release_ref: make_ref(),
        barrier_after: 99
      )

    {:ok, upstream} =
      FakeUpstream.start_link({:sequence, [FakeUpstream.sse_stream(events), processed_mode]})

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    session = start_supervised!(UpstreamWebsocketSession)

    assert {:ok, %{terminal: "response.completed"}} =
             UpstreamWebsocketSession.request(session, %WireRequest{
               url: FakeUpstream.url(upstream) <> @endpoint,
               headers: [],
               payload: "{}",
               timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000},
               writer: fn _frame -> send(observer, :processed_frame_observed) end,
               message_mapper: nil
             })

    assert_receive :processed_frame_observed, 15_000
    {session, upstream}
  end
end
