defmodule CodexPooler.FakeUpstreamTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.PoolerFixtures

  # The client's own receive timeout is the scenario clock in the timeout
  # cases: the fake holds the response until released, so the client gives up
  # first regardless of load. Keep it short; the barrier waits stay separate.
  @client_receive_timeout_ms 250

  # Detection budget for fake-side barrier notifications; the green path never
  # waits on it.
  @barrier_detection_timeout_ms 5_000

  describe "local fake upstream" do
    @tag :fake_upstream_pin
    test "legacy sequences remain permissive and repeat their final response" do
      upstream =
        start_upstream(
          {:sequence,
           [
             FakeUpstream.json_response(%{"id" => "resp_first"}),
             FakeUpstream.json_response(%{"id" => "resp_final"})
           ]}
        )

      assert %{status: 200, body: %{"id" => "resp_first"}} =
               Req.get!(FakeUpstream.url(upstream) <> "/first")

      assert %{status: 200, body: %{"id" => "resp_final"}} =
               Req.get!(FakeUpstream.url(upstream) <> "/final")

      assert %{status: 200, body: %{"id" => "resp_final"}} =
               Req.get!(FakeUpstream.url(upstream) <> "/legacy-repeat")

      assert FakeUpstream.count(upstream) == 3
    end

    @tag :fake_upstream_pin
    test "an explicit persistent response mode remains reusable" do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_persistent"}))

      for path <- ["/one", "/two"] do
        assert %{status: 200, body: %{"id" => "resp_persistent"}} =
                 Req.get!(FakeUpstream.url(upstream) <> path)
      end

      assert FakeUpstream.count(upstream) == 2
    end

    @tag :fake_upstream_strict_contract
    test "strict finite sequences consume once and reject an extra request" do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.json_response(%{"id" => "resp_once"})
          ])
        )

      assert %{status: 200, body: %{"id" => "resp_once"}} =
               Req.get!(FakeUpstream.url(upstream) <> "/once")

      assert %{status: 500, body: %{"error" => %{"code" => "fake_upstream_scenario_failure"}}} =
               Req.get!(FakeUpstream.url(upstream) <> "/extra", retry: false)

      assert_raise ExUnit.AssertionError, ~r/unexpected_extra_request.*transport=http/s, fn ->
        FakeUpstream.verify!(upstream)
      end
    end

    @tag :fake_upstream_strict_contract
    test "a strict scenario can reject the websocket handshake and keeps its accounting" do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "GET",
              headers: [required: %{"authorization" => "Bearer handshake-token"}],
              respond:
                FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "invalid_api_key"}},
                  status: 401
                )
            )
          ])
        )

      upgrade_headers = [
        {"upgrade", "websocket"},
        {"connection", "upgrade"},
        {"authorization", "Bearer handshake-token"}
      ]

      assert %{status: 401, body: %{"error" => %{"code" => "invalid_api_key"}}} =
               Req.get!(FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
                 headers: upgrade_headers,
                 retry: false
               )

      # The rejected handshake is neither a request nor a connection.
      assert FakeUpstream.requests(upstream) == []
      assert FakeUpstream.websocket_connection_count(upstream) == 0
      assert :ok = FakeUpstream.verify!(upstream)

      # A second handshake is an extra request against the finite scenario.
      assert %{status: 500, body: %{"error" => %{"code" => "fake_upstream_scenario_failure"}}} =
               Req.get!(FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
                 headers: upgrade_headers,
                 retry: false
               )

      assert_raise ExUnit.AssertionError, ~r/unexpected_extra_request/, fn ->
        FakeUpstream.verify!(upstream)
      end
    end

    @tag :fake_upstream_strict_contract
    test "a strict handshake rejection checks its expectations against the upgrade request" do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "GET",
              headers: [required: %{"authorization" => "Bearer expected-token"}],
              respond:
                FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "invalid_api_key"}},
                  status: 401
                )
            )
          ])
        )

      assert %{status: 500, body: %{"error" => %{"code" => "fake_upstream_scenario_failure"}}} =
               Req.get!(FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
                 headers: [
                   {"upgrade", "websocket"},
                   {"connection", "upgrade"},
                   {"authorization", "Bearer other-token"}
                 ],
                 retry: false
               )

      assert_raise ExUnit.AssertionError,
                   ~r/expectation_mismatch field=headers\.authorization expected="Bearer expected-token" actual="Bearer other-token"/,
                   fn -> FakeUpstream.verify!(upstream) end
    end

    @tag :fake_upstream_strict_contract
    test "repeat-last behavior is explicit" do
      upstream =
        start_upstream(
          FakeUpstream.repeat_last([
            FakeUpstream.json_response(%{"id" => "resp_first"}),
            FakeUpstream.json_response(%{"id" => "resp_repeat"})
          ])
        )

      assert %{body: %{"id" => "resp_first"}} =
               Req.get!(FakeUpstream.url(upstream) <> "/first")

      for path <- ["/second", "/third"] do
        assert %{body: %{"id" => "resp_repeat"}} =
                 Req.get!(FakeUpstream.url(upstream) <> path)
      end

      assert :ok = FakeUpstream.verify!(upstream)
    end

    @tag :fake_upstream_strict_contract
    test "final verification rejects an unused strict entry" do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.json_response(%{"id" => "resp_expected"})
          ])
        )

      assert_raise ExUnit.AssertionError,
                   ~r/unused_strict_entries.*remaining=1.*consumed=0/s,
                   fn -> FakeUpstream.verify!(upstream) end
    end

    @tag :fake_upstream_strict_contract
    test "request expectations withhold success and expose exact structural mismatch" do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              headers: [required: %{"x-synthetic-contract" => "expected"}, forbidden: ["x-bad"]],
              json: [
                valid: true,
                required: ["type", "input.0.role"],
                forbidden: ["unsupported_field"],
                equals: %{
                  "type" => "response.create",
                  "input.0.role" => "user"
                }
              ],
              respond: FakeUpstream.json_response(%{"id" => "resp_should_not_escape"})
            )
          ])
        )

      response =
        Req.post!(FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
          json: %{"type" => "wrong.create", "input" => [%{"role" => "assistant"}]},
          headers: [{"x-synthetic-contract", "actual"}, {"x-bad", "present"}],
          retry: false
        )

      assert response.status == 500
      refute response.body["id"] == "resp_should_not_escape"

      assert_raise ExUnit.AssertionError,
                   ~r/expectation_mismatch.*headers.x-synthetic-contract.*expected="expected".*actual="actual".*headers.x-bad.*expected=:forbidden.*actual="present".*json.input.0.role.*expected="user".*actual="assistant".*json.type.*expected="response.create".*actual="wrong.create"/s,
                   fn -> FakeUpstream.verify!(upstream) end
    end

    @tag :fake_upstream_strict_contract
    test "request expectations reject invalid JSON and missing required paths" do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/strict-json",
              json: [valid: true, required: ["type"]],
              respond: FakeUpstream.json_response(%{"id" => "resp_invalid_json"})
            )
          ])
        )

      response =
        Req.post!(FakeUpstream.url(upstream) <> "/strict-json",
          body: "{not-json",
          headers: [{"content-type", "application/json"}],
          retry: false
        )

      assert response.status == 500

      assert_raise ExUnit.AssertionError,
                   ~r/expectation_mismatch.*json.*expected=:valid_json.*actual=:invalid_json.*json.type.*expected=:required.*actual=:missing/s,
                   fn -> FakeUpstream.verify!(upstream) end
    end

    @tag :fake_upstream_strict_contract
    test "request expectations report method path and forbidden JSON mismatches" do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/expected-path",
              json: [valid: true, forbidden: ["forbidden.nested"]],
              respond: FakeUpstream.json_response(%{"id" => "resp_mismatch"})
            )
          ])
        )

      assert %{status: 500} =
               Req.put!(FakeUpstream.url(upstream) <> "/actual-path",
                 json: %{"forbidden" => %{"nested" => "synthetic-value"}},
                 retry: false
               )

      assert_raise ExUnit.AssertionError,
                   ~r/expectation_mismatch.*field=method expected="POST" actual="PUT".*field=path expected="\/expected-path" actual="\/actual-path".*field=json.forbidden.nested expected=:forbidden actual="synthetic-value"/s,
                   fn -> FakeUpstream.verify!(upstream) end
    end

    @tag :fake_upstream_strict_contract
    test "final verification requires registered barrier acknowledgements" do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused-permissive"}))
      barrier_ref = make_ref()
      :ok = FakeUpstream.require_acknowledgement(upstream, {:barrier, barrier_ref})

      assert_raise ExUnit.AssertionError,
                   ~r/missing_required_acknowledgement.*barrier/s,
                   fn -> FakeUpstream.verify!(upstream) end

      :ok = FakeUpstream.acknowledge(upstream, {:barrier, barrier_ref})
      assert :ok = FakeUpstream.verify!(upstream)
    end

    @tag :fake_upstream_strict_contract
    test "native frame barriers push one frame per release and keep the connection open" do
      turn_ref = make_ref()
      ack_ref = make_ref()
      created = websocket_event("response.created", "resp_frame_barrier")
      completed = websocket_event("response.completed", "resp_frame_barrier")

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              path: "/backend-api/codex/responses",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create"}],
              respond:
                FakeUpstream.barrier_websocket_frames([created, completed],
                  notify: self(),
                  release_ref: turn_ref
                )
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.processed"}],
              respond:
                FakeUpstream.barrier_websocket_frames([], notify: self(), release_ref: ack_ref)
            )
          ])
        )

      client = websocket_connect(upstream)
      client = websocket_send(client, ~s({"type":"response.create"}))

      # Nothing is pushed before the first release, and the next barrier only
      # appears once the previous one has been released.
      assert_receive {:fake_upstream_frame_barrier, 0, handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert is_pid(handler)
      assert {:timeout, client} = websocket_recv(client, 100)
      refute_received {:fake_upstream_frame_barrier, 1, _, ^turn_ref}

      assert :ok = FakeUpstream.release_frame(upstream, turn_ref)

      assert_receive {:fake_upstream_frame_barrier, 1, ^handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert {:ok, client, [^created]} = websocket_recv(client, @barrier_detection_timeout_ms)
      assert {:timeout, client} = websocket_recv(client, 100)

      assert :ok = FakeUpstream.release_frame(upstream, turn_ref)

      assert_receive {:fake_upstream_frame_barrier, 2, ^handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert {:ok, client, [^completed]} = websocket_recv(client, @barrier_detection_timeout_ms)

      # The connection stays open after the last frame: a second request on the
      # same connection is only consumed once the trailing barrier is released.
      client = websocket_send(client, ~s({"type":"response.processed"}))
      refute_receive {:fake_upstream_frame_barrier, 0, _, ^ack_ref}, 100
      assert :ok = FakeUpstream.release_frame(upstream, turn_ref)

      assert_receive {:fake_upstream_frame_barrier, 0, ^handler, ^ack_ref},
                     @barrier_detection_timeout_ms

      assert :ok = FakeUpstream.release_frame(upstream, ack_ref)
      assert {:timeout, client} = websocket_recv(client, 100)
      assert Mint.HTTP.open?(client.conn)
      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert [turn_request, ack_request] = FakeUpstream.requests(upstream)
      assert turn_request.json == %{"type" => "response.create"}
      assert ack_request.json == %{"type" => "response.processed"}
      assert :ok = FakeUpstream.verify!(upstream)
      assert {:error, :no_frame_barrier_waiting} = FakeUpstream.release_frame(upstream, turn_ref)
    end

    @tag :fake_upstream_strict_contract
    test "releasing the remaining frame barriers pushes the rest while still notifying" do
      turn_ref = make_ref()
      created = websocket_event("response.created", "resp_frame_release_all")
      completed = websocket_event("response.completed", "resp_frame_release_all")

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              json: [valid: true],
              respond:
                FakeUpstream.barrier_websocket_frames([created, completed],
                  notify: self(),
                  release_ref: turn_ref
                )
            )
          ])
        )

      client = websocket_connect(upstream)
      client = websocket_send(client, "{}")

      assert_receive {:fake_upstream_frame_barrier, 0, handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert :ok = FakeUpstream.release_remaining_frames(upstream, turn_ref)

      assert_receive {:fake_upstream_frame_barrier, 1, ^handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert_receive {:fake_upstream_frame_barrier, 2, ^handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert {:ok, client, frames} =
               websocket_recv_count(client, 2, @barrier_detection_timeout_ms)

      assert frames == [created, completed]
      assert Mint.HTTP.open?(client.conn)
      assert :ok = FakeUpstream.verify!(upstream)
    end

    @tag :fake_upstream_strict_contract
    test "final verification reports an unreleased frame barrier" do
      turn_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.barrier_websocket_frames(
              [websocket_event("response.completed", "resp_frame_unreleased")],
              notify: self(),
              release_ref: turn_ref
            )
          ])
        )

      client = websocket_connect(upstream)
      _client = websocket_send(client, "{}")

      assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert_raise ExUnit.AssertionError,
                   ~r/missing_required_acknowledgement acknowledgement=\{:frame_barrier, #Reference<[^>]+>, 0\}\n.*frame_barrier, #Reference<[^>]+>, 1\}/s,
                   fn -> FakeUpstream.verify!(upstream) end

      assert :ok = FakeUpstream.release_remaining_frames(upstream, turn_ref)

      assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert :ok = FakeUpstream.verify!(upstream)
    end

    @tag :fake_upstream_strict_contract
    test "stopping the fake while a frame barrier is held does not wait out the shutdown timeout" do
      turn_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_websocket_frames(
            [websocket_event("response.completed", "resp_frame_held_at_stop")],
            notify: self(),
            release_ref: turn_ref
          )
        )

      client = websocket_connect(upstream)
      _client = websocket_send(client, "{}")

      assert_receive {:fake_upstream_frame_barrier, 0, handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      monitor = Process.monitor(handler)
      started_at = System.monotonic_time(:millisecond)
      assert :ok = FakeUpstream.stop(upstream)
      assert_receive {:DOWN, ^monitor, :process, ^handler, _reason}, @barrier_detection_timeout_ms

      # ThousandIsland brutal-kills a connection that ignores the shutdown exit
      # only after 15 s; the held barrier must leave well before that.
      assert System.monotonic_time(:millisecond) - started_at < @barrier_detection_timeout_ms
    end

    @tag :fake_upstream_strict_contract
    test "an exhausted scenario refuses the next handshake after a frame barrier reply" do
      turn_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              json: [valid: true, equals: %{"type" => "response.create"}],
              respond:
                FakeUpstream.barrier_websocket_frames([], notify: self(), release_ref: turn_ref)
            )
          ])
        )

      client = websocket_connect(upstream)
      _client = websocket_send(client, ~s({"type":"response.create"}))

      assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^turn_ref},
                     @barrier_detection_timeout_ms

      assert :ok = FakeUpstream.release_frame(upstream, turn_ref)
      assert :ok = FakeUpstream.verify!(upstream)

      assert %{status: 500, body: %{"error" => %{"code" => "fake_upstream_scenario_failure"}}} =
               Req.get!(FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
                 headers: [{"upgrade", "websocket"}, {"connection", "upgrade"}],
                 retry: false
               )

      assert FakeUpstream.websocket_connection_count(upstream) == 1

      assert_raise ExUnit.AssertionError, ~r/unexpected_extra_request.*transport=http/s, fn ->
        FakeUpstream.verify!(upstream)
      end
    end

    @tag :fake_upstream_strict_contract
    test "a frame barrier reply withholds every frame when its request expectation fails" do
      turn_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              json: [valid: true, equals: %{"type" => "response.create"}],
              respond:
                FakeUpstream.barrier_websocket_frames(
                  [websocket_event("response.completed", "resp_frame_withheld")],
                  notify: self(),
                  release_ref: turn_ref
                )
            )
          ])
        )

      client = websocket_connect(upstream)
      client = websocket_send(client, ~s({"type":"response.cancel"}))

      assert {:ok, _client, [{:close, 1011, "fake upstream scenario failure"}]} =
               websocket_recv_raw(client, @barrier_detection_timeout_ms)

      refute_received {:fake_upstream_frame_barrier, _, _, ^turn_ref}

      assert_raise ExUnit.AssertionError,
                   ~r/expectation_mismatch field=json.type expected="response.create" actual="response.cancel"/,
                   fn -> FakeUpstream.verify!(upstream) end
    end

    test "keeps the existing low-level failure modes deterministic" do
      release_ref = make_ref()

      assert FakeUpstream.http_500_json_error() ==
               {:json_error, 500, %{"error" => %{"code" => "server_error"}}}

      assert FakeUpstream.non_json_502() == {:non_json_error, 502, "bad gateway"}

      assert FakeUpstream.timeout_before_headers(release_ref: release_ref) ==
               {:timeout_before_headers, nil, release_ref}

      assert FakeUpstream.timeout_mid_stream("data: partial\n\n", release_ref: release_ref) ==
               {:timeout_mid_stream, "data: partial\n\n", nil, release_ref}

      assert FakeUpstream.websocket_sse_then_close([], code: 1011, reason: "synthetic close") ==
               {:websocket_sse_then_close, [], 1011, "synthetic close"}
    end

    test "serves deterministic JSON responses and captures request details" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{"id" => "resp_test", "status" => "completed"})
        )

      response =
        Req.post!(FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
          json: %{"model" => "gpt-5.4-mini", "input" => "say hello"},
          headers: [{"authorization", "Bearer upstream-token"}]
        )

      assert response.status == 200
      assert response.body["id"] == "resp_test"

      assert [request] = FakeUpstream.requests(upstream)
      assert request.method == "POST"
      assert request.path == "/backend-api/codex/responses"
      assert request.json["model"] == "gpt-5.4-mini"
      assert {"authorization", "Bearer upstream-token"} in request.headers
    end

    test "streams ordered SSE chunks and a done marker" do
      upstream =
        start_upstream(
          FakeUpstream.sse_stream([
            {"response.output_text.delta", %{"delta" => "hello"}},
            {"response.completed", %{"id" => "resp_stream", "usage" => %{"total_tokens" => 14}}}
          ])
        )

      response =
        Req.get!(FakeUpstream.url(upstream) <> "/backend-api/codex/responses", into: :self)

      assert response.status == 200
      assert ["text/event-stream" <> _] = Req.Response.get_header(response, "content-type")

      chunks = receive_stream_chunks(response, 3)

      assert Enum.at(chunks, 0) =~ "event: response.output_text.delta"
      assert Enum.at(chunks, 1) =~ "event: response.completed"
      assert Enum.at(chunks, 2) == "data: [DONE]\n\n"
    end

    test "supports deterministic malformed and upstream error payloads" do
      malformed = start_upstream(FakeUpstream.malformed_json())

      malformed_response =
        Req.get!(FakeUpstream.url(malformed) <> "/malformed", decode_body: false)

      assert malformed_response.status == 200
      assert malformed_response.body == "{not-json"

      json_error = start_upstream(FakeUpstream.http_500_json_error())
      json_error_response = Req.get!(FakeUpstream.url(json_error) <> "/json-error", retry: false)

      assert json_error_response.status == 500
      assert json_error_response.body["error"]["code"] == "server_error"

      non_json = start_upstream(FakeUpstream.non_json_502())
      non_json_response = Req.get!(FakeUpstream.url(non_json) <> "/non-json", retry: false)

      assert non_json_response.status == 502
      assert non_json_response.body == "bad gateway"
    end

    test "serves quota-shaped, generic 429, and generic 5xx failures" do
      quota = start_upstream(FakeUpstream.quota_exhausted_429())
      quota_response = Req.get!(FakeUpstream.url(quota) <> "/quota", retry: false)

      assert quota_response.status == 429
      assert quota_response.body["error"]["code"] == "rate_limit_exceeded"

      assert Req.Response.get_header(quota_response, "x-codex-rate-limit-reached-type") == [
               "workspace_owner_usage_limit_reached"
             ]

      generic = start_upstream(FakeUpstream.generic_429())
      generic_response = Req.get!(FakeUpstream.url(generic) <> "/generic", retry: false)

      assert generic_response.status == 429
      assert Req.Response.get_header(generic_response, "x-codex-rate-limit-reached-type") == []

      server = start_upstream(FakeUpstream.generic_5xx())
      server_response = Req.get!(FakeUpstream.url(server) <> "/server", retry: false)

      assert server_response.status == 503
      assert server_response.body["error"]["code"] == "server_error"
    end

    test "closes the HTTP connection before headers" do
      upstream = start_upstream(FakeUpstream.close_before_headers())

      assert {:error, error} =
               Req.get(FakeUpstream.url(upstream) <> "/close", retry: false)

      assert transport_closed?(error)
    end

    test "holds response headers behind the dedicated owner-liveness gate" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.gated_json_headers(%{"id" => "resp_gated_headers"},
            notify: self(),
            release_ref: release_ref
          )
        )

      task = Task.async(fn -> Req.get!(FakeUpstream.url(upstream) <> "/gated-headers") end)

      assert_receive {:fake_upstream_gate, :before_headers, upstream_pid, ^release_ref}, 1_000
      refute Task.yield(task, 0)

      send(upstream_pid, {:fake_upstream_release_gate, release_ref})

      assert %{status: 200, body: %{"id" => "resp_gated_headers"}} = Task.await(task, 2_000)
    end

    test "holds SSE response headers behind the dedicated owner-liveness gate" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.gated_sse_headers(
            [{"response.completed", %{"type" => "response.completed"}}],
            notify: self(),
            release_ref: release_ref
          )
        )

      task = Task.async(fn -> Req.get!(FakeUpstream.url(upstream) <> "/gated-sse-headers") end)

      assert_receive {:fake_upstream_gate, :before_headers, upstream_pid, ^release_ref}, 1_000
      refute Task.yield(task, 0)
      send(upstream_pid, {:fake_upstream_release_gate, release_ref})

      assert %{status: 200, body: body} = Task.await(task, 15_000)
      assert body =~ "response.completed"
      assert body =~ "data: [DONE]"
    end

    test "holds only terminal SSE data behind the dedicated owner-liveness gate" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.gated_terminal_sse_stream(
            [{"response.created", %{"type" => "response.created"}}],
            {"response.completed", %{"type" => "response.completed"}},
            notify: self(),
            release_ref: release_ref
          )
        )

      response = Req.get!(FakeUpstream.url(upstream) <> "/gated-terminal", into: :self)

      assert_receive {:fake_upstream_gate, :before_terminal, upstream_pid, ^release_ref}, 1_000
      assert {:ok, [data: created]} = receive_stream_message(response)
      assert created =~ "response.created"

      send(upstream_pid, {:fake_upstream_release_gate, release_ref})

      assert {:ok, [data: completed]} = receive_stream_message(response)
      assert completed =~ "response.completed"
      assert {:ok, [data: "data: [DONE]\n\n"]} = receive_stream_message(response)
    end

    test "holds only the terminal SSE event behind an explicit barrier" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.delayed_terminal_sse_stream(
            [{"response.created", %{"type" => "response.created"}}],
            {"response.completed", %{"type" => "response.completed"}},
            notify: self(),
            release_ref: release_ref
          )
        )

      response = Req.get!(FakeUpstream.url(upstream) <> "/late-terminal", into: :self)

      assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid,
                      ^release_ref},
                     1_000

      assert {:ok, [data: created]} = receive_stream_message(response)
      assert created =~ "response.created"

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:ok, [data: completed]} = receive_stream_message(response)
      assert completed =~ "response.completed"
      assert {:ok, [data: "data: [DONE]\n\n"]} = receive_stream_message(response)
    end

    test "builds deterministic WebSocket terminal and close failures" do
      assert {:websocket_text, [terminal]} = FakeUpstream.websocket_terminal_failure()

      assert %{
               "type" => "response.failed",
               "response" => %{
                 "status" => "failed",
                 "error" => %{"code" => "server_error"}
               }
             } = CodexPooler.JSON.decode!(terminal)

      assert FakeUpstream.websocket_close() ==
               {:websocket_sse_then_close, [], 1011, "synthetic websocket close"}

      assert {:websocket_upgrade_error, 503, %{"error" => %{"code" => "upgrade_failed"}}, [], nil,
              nil} =
               FakeUpstream.websocket_upgrade_error(
                 %{"error" => %{"code" => "upgrade_failed"}},
                 status: 503
               )
    end

    test "supports timeout before headers" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref)
        )

      assert {:error, error} =
               Req.get(FakeUpstream.url(upstream) <> "/slow",
                 receive_timeout: @client_receive_timeout_ms,
                 retry: false
               )

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                      ^release_ref},
                     1_000

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      assert transport_timeout?(error)
    end

    test "supports timeout mid-stream after visible output" do
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.timeout_mid_stream("data: partial\n\n",
            notify: self(),
            release_ref: release_ref
          )
        )

      task = stream_timeout_request(FakeUpstream.url(upstream) <> "/stream-timeout", self())

      assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref},
                     1_000

      try do
        assert_receive {:fake_upstream_stream_data, "data: partial\n\n"}, 1_000
        assert {:error, error} = Task.await(task, 2_000)

        assert transport_timeout?(error)
      after
        send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      end
    end
  end

  describe "pool-oriented gateway fixtures" do
    test "create active, paused, and missing API-key helper shapes" do
      pool = PoolerFixtures.pool_fixture()

      active = PoolerFixtures.active_api_key_fixture(pool)
      paused = PoolerFixtures.paused_api_key_fixture(pool)

      assert active.pool.id == pool.id
      assert active.api_key.status == "active"
      assert active.authorization == "Bearer #{active.raw_key}"
      refute active.api_key.key_hash == active.raw_key

      assert paused.api_key.status == "paused"
      assert paused.authorization == "Bearer #{paused.raw_key}"
      assert PoolerFixtures.missing_api_key_headers() == %{}
    end

    test "asserts accounting rows for a gateway request" do
      key = PoolerFixtures.active_api_key_fixture()
      %{assignment: assignment} = PoolerFixtures.upstream_assignment_fixture(key.pool)
      request = PoolerFixtures.request_fixture(key, %{transport: "http_sse"})
      attempt = PoolerFixtures.attempt_fixture(request, assignment, %{transport: "http_sse"})

      PoolerFixtures.ledger_entry_fixture(request, %{
        attempt_id: attempt.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        transport: "http_sse"
      })

      assert [entry] =
               PoolerFixtures.assert_accounting_for_request(request, usage_status: "usage_known")

      assert entry.transport == "http_sse"
      assert entry.total_tokens == 14
    end
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp websocket_event(type, response_id) do
    CodexPooler.JSON.encode!(%{"type" => type, "response" => %{"id" => response_id}})
  end

  defp websocket_connect(upstream) do
    uri = URI.parse(FakeUpstream.url(upstream))

    {:ok, conn} =
      Mint.HTTP.connect(:http, uri.host, uri.port, protocols: [:http1], mode: :passive)

    on_exit(fn -> Mint.HTTP.close(conn) end)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/backend-api/codex/responses", [])
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @barrier_detection_timeout_ms)
    assert {:status, ref, 101} in responses
    {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
    %{conn: conn, websocket: websocket, ref: ref}
  end

  defp websocket_send(%{conn: conn, websocket: websocket, ref: ref} = client, text) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, text})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    %{client | conn: conn, websocket: websocket}
  end

  # One passive receive: the decoded text frames of the next batch, or a timeout
  # when the fake pushed nothing within `timeout_ms`.
  defp websocket_recv(client, timeout_ms) do
    case websocket_recv_raw(client, timeout_ms) do
      {:ok, client, frames} -> {:ok, client, Enum.map(frames, fn {:text, text} -> text end)}
      {:timeout, client} -> {:timeout, client}
    end
  end

  defp websocket_recv_raw(%{conn: conn, websocket: websocket, ref: ref} = client, timeout_ms) do
    case Mint.WebSocket.recv(conn, 0, timeout_ms) do
      {:ok, conn, responses} ->
        {websocket, frames} =
          Enum.reduce(responses, {websocket, []}, fn
            {:data, ^ref, data}, {websocket, frames} ->
              {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
              {websocket, frames ++ decoded}

            _response, acc ->
              acc
          end)

        {:ok, %{client | conn: conn, websocket: websocket}, frames}

      {:error, conn, reason, []}
      when reason in [:timeout, %Mint.TransportError{reason: :timeout}] ->
        {:timeout, %{client | conn: conn}}
    end
  end

  defp websocket_recv_count(client, count, timeout_ms, acc \\ [])

  defp websocket_recv_count(client, count, _timeout_ms, acc) when length(acc) >= count,
    do: {:ok, client, Enum.take(acc, count)}

  defp websocket_recv_count(client, count, timeout_ms, acc) do
    assert {:ok, client, frames} = websocket_recv(client, timeout_ms)
    websocket_recv_count(client, count, timeout_ms, acc ++ frames)
  end

  defp receive_stream_chunks(response, count) do
    Enum.map(1..count, fn _ ->
      assert {:ok, [data: data]} = receive_stream_message(response)
      data
    end)
  end

  defp receive_stream_message(response) do
    Req.parse_message(
      response,
      receive do
        message -> message
      end
    )
  end

  defp stream_timeout_request(url, parent) do
    Task.async(fn ->
      Req.get(url,
        into: fn {:data, data}, {request, response} ->
          send(parent, {:fake_upstream_stream_data, data})
          {:cont, {request, response}}
        end,
        receive_timeout: @client_receive_timeout_ms,
        retry: false
      )
    end)
  end

  defp transport_timeout?(%Finch.TransportError{
         reason: :timeout,
         source: %Mint.TransportError{reason: :timeout}
       }),
       do: true

  defp transport_timeout?(%Req.TransportError{reason: :timeout}), do: true
  defp transport_timeout?(%Mint.TransportError{reason: :timeout}), do: true
  defp transport_timeout?(_error), do: false

  defp transport_closed?(%Finch.TransportError{reason: reason}),
    do: reason in [:closed, :connection_closed]

  defp transport_closed?(%Req.TransportError{reason: reason}),
    do: reason in [:closed, :connection_closed]

  defp transport_closed?(%Mint.TransportError{reason: reason}),
    do: reason in [:closed, :connection_closed]

  defp transport_closed?(_error), do: false
end
