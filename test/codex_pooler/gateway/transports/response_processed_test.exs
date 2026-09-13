defmodule CodexPooler.Gateway.Transports.Websocket.ResponseProcessedTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.ResponseProcessed
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request, as: WireRequest
  alias CodexPooler.Pools

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
    {session, upstream, ack_ref} = connected_session(1)
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

    # Observe the fake consuming the ack; the fake replies nothing to it, so
    # the client's turn writer is never invoked again.
    assert_ack_forwarded(upstream, ack_ref)
    assert List.last(FakeUpstream.requests(upstream)).json == payload()
    refute_received :processed_frame_observed
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "turn id takes precedence over client and server request ids", %{auth: auth} do
    {session, upstream, ack_ref} = connected_session(1)
    frame = Map.merge(payload(), %{"turn_id" => "turn-processed", "request_id" => "client"})

    assert {:ok, _} =
             ResponseProcessed.handle_prepared(
               auth,
               frame,
               options(%{upstream_websocket_session: session, request_id: "server"})
             )

    assert Repo.one!(Request).correlation_id == "turn-processed"
    assert_ack_forwarded(upstream, ack_ref)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "missing client correlation uses server id or generates an id", %{auth: auth} do
    {session, upstream, ack_ref} = connected_session(2)

    for request_id <- ["server-processed", nil] do
      assert {:ok, _} =
               ResponseProcessed.handle_prepared(
                 auth,
                 payload(),
                 options(%{upstream_websocket_session: session, request_id: request_id})
               )

      assert_ack_forwarded(upstream, ack_ref)
    end

    ids = Repo.all(from request in Request, select: request.correlation_id)
    assert "server-processed" in ids
    assert {:ok, _} = Ecto.UUID.cast(Enum.find(ids, &(&1 != "server-processed")))
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "accounting rejection after forwarding is surfaced without a success row", %{auth: auth} do
    {session, upstream, ack_ref} = connected_session(1)

    # The key authorizes, but the context lacks the Pool the metadata row needs,
    # so the failure can only come from accounting after the ack was forwarded.
    assert {:error, %{status: 500, code: "gateway_accounting_failed", accounting_error: reason}} =
             ResponseProcessed.handle_prepared(
               Map.delete(auth, :pool),
               payload(),
               options(%{upstream_websocket_session: session})
             )

    assert is_binary(reason)
    assert Repo.aggregate(Request, :count) == 0
    assert_ack_forwarded(upstream, ack_ref)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  describe "durable API-key authorization before forwarding" do
    for {invalidation, expected_code} <- [
          deleted: :api_key_missing,
          expired: :api_key_expired,
          pool_inactive: :pool_inactive
        ] do
      test "a #{invalidation} key is refused before the ack reaches the upstream websocket" do
        invalidation = unquote(invalidation)
        expected_code = unquote(expected_code)
        %{pool: pool, api_key: key} = active_api_key_fixture()
        auth = %{pool: pool, api_key: key, key_prefix: key.key_prefix}
        {session, upstream, _ack_ref} = connected_session(0)
        invalidate!(invalidation, pool, key)

        assert {:error, %{code: ^expected_code, disabling_epoch: 0}} =
                 ResponseProcessed.handle_prepared(
                   auth,
                   payload(),
                   options(%{upstream_websocket_session: session})
                 )

        assert FakeUpstream.count(upstream) == 1
        assert Repo.aggregate(Request, :count) == 0
        assert :ok = FakeUpstream.verify!(upstream)
      end
    end

    # Neither context can come from a live socket. Refusing it as a runtime
    # disposition would latch revocation and close a socket whose key is still
    # usable, so it is refused as a gateway error that carries no epoch.
    test "a context without an API key is refused before the ack reaches the upstream websocket without a revocation" do
      {session, upstream, _ack_ref} = connected_session(0)

      assert {:error, %{status: 500, code: "api_key_authorization_context_missing"} = error} =
               ResponseProcessed.handle_prepared(
                 %{key_prefix: "synthetic"},
                 payload(),
                 options(%{upstream_websocket_session: session})
               )

      refute Map.has_key?(error, :disabling_epoch)
      assert FakeUpstream.count(upstream) == 1
      assert Repo.aggregate(Request, :count) == 0
      assert :ok = FakeUpstream.verify!(upstream)
    end

    test "a context without a captured epoch is refused without inventing one" do
      %{pool: pool, api_key: key} = active_api_key_fixture()
      scope = owner_scope(key)

      # A pause and resume leaves the key usable at a later epoch, which a
      # fabricated epoch of 0 would refuse as stale.
      assert {:ok, _paused} = Access.pause_api_key(scope, key)
      assert {:ok, %APIKey{runtime_revocation_epoch: 1}} = Access.resume_api_key(scope, key)

      auth = %{pool: pool, api_key: %{id: key.id}, key_prefix: key.key_prefix}
      {session, upstream, _ack_ref} = connected_session(0)

      assert {:error, %{status: 500, code: "api_key_authorization_context_missing"} = error} =
               ResponseProcessed.handle_prepared(
                 auth,
                 payload(),
                 options(%{upstream_websocket_session: session})
               )

      refute Map.has_key?(error, :disabling_epoch)
      assert FakeUpstream.count(upstream) == 1
      assert Repo.aggregate(Request, :count) == 0
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  defp invalidate!(:deleted, _pool, key),
    do: assert({:ok, _deleted} = Access.delete_api_key(owner_scope(key), key))

  defp invalidate!(:expired, _pool, key) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    assert {1, _rows} =
             Repo.update_all(from(api_key in APIKey, where: api_key.id == ^key.id),
               set: [expires_at: past]
             )
  end

  defp invalidate!(:pool_inactive, pool, key) do
    assert {:ok, %{status: "disabled"}} =
             Pools.change_pool_status(owner_scope(key), pool, "disabled")
  end

  defp owner_scope(key) do
    User
    |> Repo.get!(key.created_by_user_id)
    |> Scope.for_user(["instance_owner"])
  end

  defp options(attrs \\ %{}), do: RequestOptions.build(attrs, @endpoint, %{})
  defp payload, do: %{"type" => "response.processed", "response_id" => "resp_sample_processed"}

  # Opens one native websocket turn and declares exactly `ack_count` processed
  # acks on the same connection. The fake replies nothing to an ack, so each
  # ack's consumption is observed through its barrier via `assert_ack_forwarded/2`.
  # With no ack declared, any forwarded ack is an unexpected request.
  defp connected_session(ack_count) when is_integer(ack_count) and ack_count >= 0 do
    observer = self()
    ack_ref = make_ref()

    completed_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_sample_processed"}
      })

    ack_entries =
      for _ <- List.duplicate(:ack, ack_count) do
        FakeUpstream.expect_request(
          method: "WEBSOCKET",
          path: @endpoint,
          websocket_connection_ordinal: 1,
          json: [valid: true, equals: %{"type" => "response.processed"}],
          respond:
            FakeUpstream.barrier_websocket_frames([], notify: observer, release_ref: ack_ref)
        )
      end

    {:ok, upstream} =
      FakeUpstream.start_link(
        # provenance: synthetic_adversarial (one-frame completed turn; the empty ack reply only observes consumption)
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: @endpoint,
            websocket_connection_ordinal: 1,
            json: [valid: true],
            respond: FakeUpstream.websocket_text_frames([completed_frame])
          )
          | ack_entries
        ])
      )

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
    {session, upstream, ack_ref}
  end

  defp assert_ack_forwarded(upstream, ack_ref) do
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^ack_ref}, 15_000
    assert :ok = FakeUpstream.release_frame(upstream, ack_ref)
  end
end
