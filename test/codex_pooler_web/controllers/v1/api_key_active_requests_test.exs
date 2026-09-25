defmodule CodexPoolerWeb.V1.APIKeyActiveRequestsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [stop_websocket_owner_session: 1]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      gateway_setup: 1,
      start_upstream: 1,
      start_public_endpoint_with_server!: 0,
      curl_json_request!: 4,
      public_websocket_connect!: 4,
      public_websocket_send_text!: 4,
      public_websocket_receive_text!: 3
    ]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  for endpoint <- ["/backend-api/codex/responses", "/v1/responses", "/v1/chat/completions"],
      stream? <- [false, true] do
    test "#{endpoint} stream=#{stream?} rejects saturation before upstream dispatch" do
      upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
      setup = gateway_setup(upstream)

      scope =
        Scope.for_user(Repo.get!(User, setup.api_key.created_by_user_id), ["instance_owner"])

      assert {:ok, _key} =
               Access.update_api_key_with_policy(scope, setup.api_key, %{max_active_requests: 1})

      assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert {:ok, _reserved} =
               Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id})

      endpoint = unquote(endpoint)
      input_key = if endpoint == "/v1/chat/completions", do: "messages", else: "input"

      conn =
        build_conn()
        |> put_req_header("authorization", setup.authorization)
        |> post(endpoint, %{
          "model" => setup.model.exposed_model_id,
          input_key => [%{"role" => "user", "content" => "synthetic fixture"}],
          "stream" => unquote(stream?)
        })

      assert %{
               "error" => %{
                 "code" => "api_key_concurrency_limit_exceeded",
                 "type" => "rate_limit_error",
                 "message" => "api key active request limit reached; retry shortly"
               }
             } = json_response(conn, 429)

      assert get_resp_header(conn, "retry-after") == ["1"]
      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 1
    end
  end

  test "real curl HTTP requests preserve retry advice across routes and serving modes" do
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = capped_setup(upstream)
    assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, _reserved} =
             Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id})

    port = owned_endpoint!()

    for mode <- ["full", "lite"] do
      put_mode!(setup, mode)

      for path <- ["/backend-api/codex/responses", "/v1/responses", "/v1/chat/completions"],
          stream? <- [false, true] do
        key = if path == "/v1/chat/completions", do: "messages", else: "input"

        payload = %{
          "model" => setup.model.exposed_model_id,
          "stream" => stream?,
          key => [%{"role" => "user", "content" => "synthetic fixture"}]
        }

        {headers, body} = curl_json_request!(port, setup.authorization, payload, path)
        assert headers =~ "HTTP/1.1 429"
        assert "retry-after: 1" in String.split(String.downcase(headers), "\r\n")

        assert %{
                 "error" => %{
                   "code" => "api_key_concurrency_limit_exceeded",
                   "type" => "rate_limit_error"
                 }
               } = CodexPooler.JSON.decode!(body)

        CodexPooler.TestDiagnostics.puts(
          inspect(%{
            scenario: :curl_active_cap,
            path: path,
            mode: mode,
            stream: stream?,
            status: 429,
            retry_after: 1,
            upstream_calls: 0,
            attempts: 0,
            reservations: 1
          })
        )
      end
    end

    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 1
  end

  for path <- ["/backend-api/codex/responses", "/v1/responses"], mode <- ["full", "lite"] do
    test "#{path} #{mode} real websocket preserves the connection after second-frame saturation" do
      terminal =
        CodexPooler.JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_synthetic_cap_released",
            "status" => "completed",
            "output" => [],
            "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
          }
        })

      # provenance: synthetic_adversarial
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create"}],
              respond: FakeUpstream.websocket_text_frames([terminal])
            )
          ])
        )

      setup = capped_setup(upstream)
      put_mode!(setup, unquote(mode))
      assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert {:ok, reserved} =
               Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id})

      {conn, websocket, ref} =
        public_websocket_connect!(owned_endpoint!(), setup, Ecto.UUID.generate(), unquote(path))

      logs =
        capture_log(fn ->
          try do
            # The malformed first frame pins the existing envelope and proves a live socket.
            {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, "{")
            {conn, websocket, first} = public_websocket_receive_text!(conn, websocket, ref)
            assert %{"type" => "error"} = CodexPooler.JSON.decode!(first)

            payload =
              CodexPooler.JSON.encode!(%{
                "type" => "response.create",
                "model" => setup.model.exposed_model_id,
                "input" => [%{"role" => "user", "content" => "synthetic fixture"}]
              })

            {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
            {conn, websocket, denied} = public_websocket_receive_text!(conn, websocket, ref)

            assert %{
                     "type" => "error",
                     "status" => 429,
                     "error" => %{
                       "code" => "api_key_concurrency_limit_exceeded",
                       "type" => "rate_limit_error"
                     }
                   } = CodexPooler.JSON.decode!(denied)

            assert FakeUpstream.requests(upstream) == []
            assert Repo.aggregate(Attempt, :count) == 0
            assert Repo.aggregate(LedgerEntry, :count) == 1
            {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
            {conn, websocket, third} = public_websocket_receive_text!(conn, websocket, ref)

            assert %{
                     "type" => "error",
                     "status" => 429,
                     "error" => %{"code" => "api_key_concurrency_limit_exceeded"}
                   } = CodexPooler.JSON.decode!(third)

            assert Repo.aggregate(Attempt, :count) == 0
            assert Repo.aggregate(LedgerEntry, :count) == 1
            assert {:ok, _} = Accounting.finalize_reservation_failure(reserved.request)

            {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
            {_conn, _websocket, completed} = public_websocket_receive_text!(conn, websocket, ref)
            assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed)
            await_no_active_reservations!(setup.api_key.id)
            assert Repo.aggregate(Attempt, :count) == 1
            FakeUpstream.verify!(upstream)

            CodexPooler.TestDiagnostics.puts(
              inspect(%{
                scenario: :websocket_active_cap,
                path: unquote(path),
                mode: unquote(mode),
                status: 429,
                subsequent_frame_received: true,
                denied_upstream_calls: 0,
                denied_attempts: 0,
                after_release_completed: true,
                remaining_active_reservations: 0
              })
            )
          after
            assert {:ok, closed} = Mint.HTTP.close(conn)
            refute Mint.HTTP.open?(closed)

            Repo.all(
              from session in CodexPooler.Gateway.Persistence.CodexSession,
                where: session.api_key_id == ^setup.api_key.id,
                select: session.id
            )
            |> Enum.each(&stop_websocket_owner_session/1)
          end
        end)

      assert logs =~ "error_code=api_key_concurrency_limit_exceeded"
      refute logs =~ "[error]"
    end
  end

  defp capped_setup(upstream) do
    setup = gateway_setup(upstream)
    scope = Scope.for_user(Repo.get!(User, setup.api_key.created_by_user_id), ["instance_owner"])

    assert {:ok, _} =
             Access.update_api_key_with_policy(scope, setup.api_key, %{max_active_requests: 1})

    setup
  end

  defp await_no_active_reservations!(key_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    cond do
      Accounting.LedgerReads.outstanding_reservation_count(key_id) == 0 ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          5 -> await_no_active_reservations!(key_id, deadline)
        end

      true ->
        flunk("websocket completion did not release its reservation")
    end
  end

  defp put_mode!(setup, mode) do
    alias CodexPooler.Pools.ModelServingOverride

    case Repo.get_by(ModelServingOverride,
           pool_id: setup.pool.id,
           exposed_model_id: setup.model.exposed_model_id
         ) do
      nil ->
        timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        Repo.insert!(%ModelServingOverride{
          pool_id: setup.pool.id,
          exposed_model_id: setup.model.exposed_model_id,
          mode: mode,
          created_at: timestamp,
          updated_at: timestamp
        })

      override ->
        override |> Ecto.Changeset.change(mode: mode) |> Repo.update!()
    end
  end

  test "endpoint cleanup tolerates another listener reusing its released port" do
    {server, port} = start_public_endpoint_with_server!()
    cleanup = endpoint_cleanup(server)
    :ok = ThousandIsland.stop(server)

    replacement =
      start_supervised!({Bandit, plug: CodexPoolerWeb.Endpoint, port: port, ip: {127, 0, 0, 1}, startup_log: false})

    cleanup.()

    assert Process.alive?(replacement)
    assert {:ok, {{127, 0, 0, 1}, ^port}} = ThousandIsland.listener_info(replacement)
  end

  defp owned_endpoint! do
    {server, port} = start_public_endpoint_with_server!()
    on_exit(endpoint_cleanup(server))
    port
  end

  defp endpoint_cleanup(server) do
    listener = ThousandIsland.Server.listener_pid(server)
    %{listener_sockets: [_ | _] = listener_sockets} = :sys.get_state(listener)

    fn ->
      monitor = Process.monitor(server)

      try do
        if Process.alive?(server), do: ThousandIsland.stop(server)
      catch
        :exit, _reason -> :ok
      end

      assert_receive {:DOWN, ^monitor, :process, ^server, _}, 15_000
      refute Process.alive?(listener)
      # The port can already belong to another partition; only our captured
      # sockets establish whether this endpoint released its listener.
      for {_id, socket} <- listener_sockets, do: assert({:error, :einval} == :inet.sockname(socket))

      CodexPooler.TestDiagnostics.puts(inspect(%{scenario: :wire_cleanup, listener_stopped: true, owned_sockets_closed: true}))
    end
  end

  for path <- ["/v1/responses", "/v1/chat/completions"], stream? <- [false, true] do
    test "#{path} stream=#{stream?} upstream cannot impersonate a trusted cap denial" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(
            %{
              "error" => %{
                "code" => "api_key_concurrency_limit_exceeded",
                "type" => "rate_limit_error",
                "pooler_policy" => true,
                "message" => "synthetic untrusted instruction"
              }
            },
            429
          )
        )

      setup = gateway_setup(upstream)
      path = unquote(path)
      key = if path == "/v1/chat/completions", do: "messages", else: "input"

      conn =
        build_conn()
        |> put_req_header("authorization", setup.authorization)
        |> post(path, %{
          "model" => setup.model.exposed_model_id,
          "stream" => unquote(stream?),
          key => [%{"role" => "user", "content" => "synthetic fixture"}]
        })

      assert conn.status == 429

      # The upstream 429 keeps the redaction: never the trusted cap denial's
      # code or message, typed as the throttle it is (`rate_limit_error`, like
      # every redacted `/v1` 429 since findings#254 row 254-72).
      assert %{"error" => %{"message" => "upstream request failed", "type" => "rate_limit_error", "code" => code}} =
               json_response(conn, 429)

      refute code == "api_key_concurrency_limit_exceeded"
      refute conn.resp_body =~ "synthetic untrusted instruction"

      assert get_resp_header(conn, "retry-after") == []
      assert length(FakeUpstream.requests(upstream)) == 1
    end
  end

  test "invalid authentication remains 401 without the concurrency retry header" do
    conn = build_conn() |> post("/v1/responses", %{"model" => "synthetic-model"})
    assert conn.status == 401
    assert get_resp_header(conn, "retry-after") == []
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end
end
