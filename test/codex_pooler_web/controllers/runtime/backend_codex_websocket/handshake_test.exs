defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.HandshakeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  @websocket_frame_timeout 1_000
  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000

  defmodule TinyTimeoutPlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn
      |> WebSockAdapter.upgrade(
        CodexPoolerWeb.Runtime.BackendCodexWebsocket.HandshakeTest.TinyTimeoutSocket,
        %{test_pid: Keyword.fetch!(opts, :test_pid)},
        timeout: Keyword.fetch!(opts, :timeout_ms),
        compress: false
      )
      |> halt()
    end
  end

  defmodule TinyTimeoutSocket do
    @moduledoc false

    @behaviour WebSock

    @impl WebSock
    def init(state), do: {:ok, state}

    @impl WebSock
    def handle_in({text, [opcode: :text]}, state), do: {:push, {:text, text}, state}

    @impl WebSock
    def handle_info(_message, state), do: {:ok, state}

    @impl WebSock
    def terminate(reason, %{test_pid: test_pid}) do
      send(test_pid, {:tiny_timeout_terminated, reason})
      :ok
    end
  end

  test "GET /backend-api/codex/responses requires websocket upgrade", %{conn: conn} do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))

    conn = conn |> auth(setup) |> get("/backend-api/codex/responses")

    assert json_response(conn, 400)["error"]["code"] == "websocket_upgrade_required"
  end

  test "direct websocket handshake derives residency from the selected encrypted access token" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_residency_direct",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)
    residency = "ws-direct-region-#{System.unique_integer([:positive])}"
    access_token = synthetic_access_token(residency)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "access_token",
               plaintext: access_token
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    logs =
      capture_log(fn ->
        capture_stream_outcome_telemetry(fn ->
          assert :ok =
                   execute_websocket_response(
                     auth,
                     websocket_auth_refresh_payload(setup, "direct-residency"),
                     %{request_id: "ws-direct-residency"},
                     fn frame -> send(self(), {:websocket_frame, frame}) end
                   )

          assert_receive {:stream_outcome, telemetry_metadata}
          refute inspect(telemetry_metadata) =~ residency
          refute inspect(telemetry_metadata) =~ access_token
        end)
      end)

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_residency_direct"} = CodexPooler.JSON.decode!(frame)
    assert [captured] = FakeUpstream.requests(upstream)

    assert header_values(captured.headers, "x-openai-internal-codex-residency") == [residency]

    assert header_values(captured.headers, "chatgpt-account-id") == [
             setup.identity.chatgpt_account_id
           ]

    assert_websocket_values_not_persisted!(setup, [residency, access_token], logs)
  end

  test "direct websocket handshake suppresses malformed and no-constraint residency claims" do
    for {label, access_token} <- [
          {"malformed", "malformed-websocket-access-token"},
          {"no-constraint", synthetic_access_token("no_constraint")}
        ] do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_residency_suppressed_#{label}",
            "object" => "response"
          })
        )

      setup = gateway_setup(upstream)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(setup.identity, %{
                 secret_kind: "access_token",
                 plaintext: access_token
               })

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert :ok =
               execute_websocket_response(
                 auth,
                 websocket_auth_refresh_payload(setup, label),
                 %{request_id: "ws-residency-suppressed-#{label}"},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_received {:websocket_frame, frame}
      expected_id = "resp_ws_residency_suppressed_#{label}"
      assert %{"id" => ^expected_id} = CodexPooler.JSON.decode!(frame)
      assert [captured] = FakeUpstream.requests(upstream)
      assert header_values(captured.headers, "x-openai-internal-codex-residency") == []

      assert header_values(captured.headers, "chatgpt-account-id") == [
               setup.identity.chatgpt_account_id
             ]
    end
  end

  @tag :encrypted_reasoning_continuity
  test "decoded websocket response.create retains current reasoning without alias state" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_current_reasoning_stateless",
          "object" => "response",
          "status" => "completed",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    raw_prompt_cache_key = "synthetic-websocket-current-reasoning-key"
    alias_count = Repo.aggregate(BridgeSessionAlias, :count)

    reasoning = %{
      "type" => "reasoning",
      "content" => nil,
      "encrypted_content" => "synthetic-websocket-current-reasoning"
    }

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "prompt_cache_key" => raw_prompt_cache_key,
        "input" => [reasoning],
        "stream" => true,
        "generate" => true
      })

    assert :ok =
             execute_websocket_response(
               auth,
               payload,
               %{request_id: "ws-current-reasoning-stateless"},
               fn _frame -> :ok end
             )

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["input"] == [reasoning]
    assert Repo.aggregate(BridgeSessionAlias, :count) == alias_count

    metadata_text = inspect({Repo.all(BridgeSessionAlias), Repo.all(Request), Repo.all(Attempt)})
    refute metadata_text =~ raw_prompt_cache_key
    refute metadata_text =~ reasoning["encrypted_content"]
  end

  test "GET /backend-api/codex/responses replaces whitespace-only websocket turn state" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    port = start_public_endpoint!()

    {conn, _websocket, _ref, response_headers} =
      public_websocket_connect_with_headers!(port, setup, "   ")

    try do
      assert {"x-codex-turn-state", turn_state} =
               List.keyfind(response_headers, "x-codex-turn-state", 0)

      assert {:ok, ^turn_state} = Ecto.UUID.cast(turn_state)
    after
      Mint.HTTP.close(conn)
    end
  end

  test "backend Responses websocket rejects malformed API-key policy before upgrade or accounting",
       %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    authenticated_conn = auth(conn, setup)
    assert {:ok, auth_context} = GatewayHelpers.authenticate(authenticated_conn)

    malformed_auth = %{
      auth_context
      | api_key: %{auth_context.api_key | metadata: %{"labels" => [42]}}
    }

    request_count = Repo.aggregate(Request, :count)

    conn =
      authenticated_conn
      |> Plug.Conn.put_private(:runtime_api_auth, malformed_auth)
      |> get("/backend-api/codex/responses")

    refute conn.status == 101
    assert conn.status in [400, 403]
    assert get_resp_header(conn, "x-models-etag") == []
    assert Repo.aggregate(Request, :count) == request_count + 1

    refute Repo.exists?(
             from(r in Request,
               where: fragment("?->>'operation'", r.request_metadata) == "models"
             )
           )

    assert FakeUpstream.count(upstream) == 0
  end

  test "backend Responses websocket authentication failure skips catalog work", %{conn: conn} do
    conn = get(conn, "/backend-api/codex/responses")

    assert conn.status == 401
    assert get_resp_header(conn, "x-models-etag") == []
    assert Repo.aggregate(Request, :count) == 0
  end

  test "GET /backend-api/codex/responses keeps production-min idle open before delayed response" do
    setup_runtime_ingress_override(%OperationalSettings{
      max_decompressed_body_bytes: 12_000,
      upstream_receive_timeout_ms: 1_000,
      websocket_idle_timeout_ms: 60_000
    })

    upstream =
      start_upstream(
        FakeUpstream.delayed_sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_ws_min_idle_delayed",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          interval_ms: 120
        )
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "public-ws-min-idle-#{System.unique_integer([:positive])}"

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    started = System.monotonic_time(:millisecond)

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input(String.duplicate("x", 7_000)),
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
      elapsed_ms = System.monotonic_time(:millisecond) - started

      assert elapsed_ms >= 100

      assert %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_ws_min_idle_delayed"}
             } =
               CodexPooler.JSON.decode!(frame)

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"status" => "succeeded"}
                      }},
                     @websocket_frame_timeout

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /backend-api/codex/responses rejects frames above the configured body cap" do
    setup_runtime_ingress_override(%OperationalSettings{
      max_decompressed_body_bytes: 700,
      websocket_idle_timeout_ms: 60_000
    })

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused_oversized_frame"}))
    setup = gateway_setup(upstream)
    {server, port} = start_public_endpoint_with_server!()
    turn_state = "public-ws-oversized-frame-#{System.unique_integer([:positive])}"

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
      monitor_ref = Process.monitor(connection_pid)

      # Bandit logs the protocol error only after it has written the close
      # frame, so the capture has to stay open until the connection process is
      # gone: releasing it on the close frame alone leaks the expected
      # "** (exit) {:deserializing, :max_frame_size_exceeded}" line to the
      # console on a loaded run.
      {{conn, _websocket, code, reason}, _logs} =
        with_log(fn ->
          {conn, websocket} =
            public_websocket_send_text!(conn, websocket, ref, String.duplicate("x", 1_000))

          result = public_websocket_receive_close!(conn, websocket, ref)

          assert_receive {:DOWN, ^monitor_ref, :process, ^connection_pid, _reason},
                         @connection_shutdown_timeout_ms

          Logger.flush()
          result
        end)

      assert code == 1009
      assert reason == ""
      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Request, :count) == 0

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /backend-api/codex/responses rejects fragmented messages above the configured body cap" do
    setup_runtime_ingress_override(%OperationalSettings{
      max_decompressed_body_bytes: 700,
      websocket_idle_timeout_ms: 60_000
    })

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused_fragmented_frame"}))
    setup = gateway_setup(upstream)
    {server, port} = start_public_endpoint_with_server!()
    turn_state = "public-ws-fragmented-frame-#{System.unique_integer([:positive])}"

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)

    try do
      assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
      monitor_ref = Process.monitor(connection_pid)

      {{conn, _websocket, code, reason}, _logs} =
        with_log(fn ->
          {conn, websocket} =
            public_websocket_send_fragmented_text!(
              conn,
              websocket,
              ref,
              String.duplicate("x", 400),
              String.duplicate("x", 400)
            )

          result = public_websocket_receive_close!(conn, websocket, ref)

          assert_receive {:DOWN, ^monitor_ref, :process, ^connection_pid, _reason},
                         @connection_shutdown_timeout_ms

          Logger.flush()
          result
        end)

      assert code == 1009
      assert reason == ""
      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Request, :count) == 0

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "direct tiny websocket timeout harness closes with sanitized reason" do
    port = start_tiny_timeout_endpoint!(25)
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/tiny-timeout", [])
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      assert_receive {:tiny_timeout_terminated, :timeout}, 1_000
      {conn, _websocket, code, reason} = public_websocket_receive_close!(conn, websocket, ref)

      assert code == 1002
      assert reason == ""

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /backend-api/codex/v1/responses upgrades through the websocket alias route" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_public_ws_v1_alias_route",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()
    turn_state = "public-ws-v1-alias-route-#{System.unique_integer([:positive])}"

    {conn, websocket, ref} =
      public_websocket_connect!(port, setup, turn_state, "/backend-api/codex/v1/responses")

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_public_ws_v1_alias_route"} = CodexPooler.JSON.decode!(frame)

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"request_id" => request_id, "status" => "succeeded"}
                      }},
                     @websocket_frame_timeout

      request = Repo.get!(Request, request_id)
      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"

      conn
    after
      Mint.HTTP.close(conn)
    end
  end

  defp setup_runtime_ingress_override(%OperationalSettings{} = settings) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end

  defp start_tiny_timeout_endpoint!(timeout_ms) do
    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.TinyTimeoutPlug, test_pid: self(), timeout_ms: timeout_ms},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end
end
