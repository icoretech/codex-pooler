defmodule CodexPooler.FakeUpstreamTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.PoolerFixtures

  describe "local fake upstream" do
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
             } = Jason.decode!(terminal)

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
                 receive_timeout: 1_000,
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
        receive_timeout: 1_000,
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
