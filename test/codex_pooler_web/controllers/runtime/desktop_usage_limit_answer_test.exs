defmodule CodexPoolerWeb.Runtime.DesktopUsageLimitAnswerTest do
  # The Codex Desktop app never showed its user the Pool's reset (findings#279
  # point 2). It answers the Pool-exhausted refusal, `429` with `error.type`
  # `usage_limit_reached`, with its own usage-limit screen, built from the
  # signed-in ChatGPT account and the app's own usage query, while it shows
  # the message of a `400` whose `error.code` is `invalid_prompt` as sent
  # (probed with an isolated Desktop 26.924.22138 against a local fake
  # target). A native Responses route therefore answers a request whose
  # `originator` is `Codex Desktop` with that `400`: the Pool's reset written
  # in the message (its UTC time and how long until then), `resets_at` and
  # `resets_in_seconds`; HTTP sends `x-should-retry: false` and no
  # `Retry-After`, the websocket error event no `headers`.
  #
  # Unchanged: every other originator (the TUI's `codex-tui`, `codex_exec`,
  # the IDE extension's `codex_vscode`, none at all), `/v1` over HTTP and
  # websocket, the retryable `503` without a known reset, and what is
  # recorded: the refused row keeps the `429` refusal, `quota_exhausted` and
  # the advised reset, and the lines name the same reset.
  #
  # Headers: the Codex session headers the released clients send, and each
  # client's own `originator` and `user-agent`; synthetic values.
  #
  # Topology: the real public listener, one node; native HTTP SSE, the native
  # websocket with owner forwarding off (the socket's own session) and on
  # (the session's owner on this node), `/v1/responses` over HTTP and
  # websocket; the refusal from routing (every candidate exhausted with a
  # known reset, nothing dispatched) and from the last candidate's provider
  # usage limit (an HTTP `429`, and the upstream websocket's wrapped `429`
  # frame). The Pool's default mode, which serves this fixture's model Full.
  # FakeUpstream.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @moduletag capture_log: true

  @turn_path "/backend-api/codex/responses"
  @desktop "Codex Desktop"
  # provenance: observed from the released Codex Desktop 26.924.22138 (core 0.158.0-alpha.2.1) on its websocket upgrade and GET /models against a local fake target
  @desktop_user_agent "Codex Desktop/0.158.0-alpha.2.1 (Mac OS 27.0.0; arm64) unknown (Codex Desktop; 26.924.22138)"
  # provenance: observed `codex-tui` and `codex_exec` from the released 0.158.0 CLI against a local fake target; `codex_vscode` from the client source (codex-rs/otel/src/metrics/tags.rs), not observed
  @other_originators ["codex-tui", "codex_exec", "codex_vscode", nil]
  @native_http_paths ["/backend-api/codex/responses", "/backend-api/codex/v1/responses", "/backend-api/codex/responses/compact", "/backend-api/codex/v1/responses/compact"]
  @native_websocket_paths ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"]
  @reset_seconds 900
  @provider_reset_seconds 3_600

  # The request line and the socket's turn-failed line are `info`, below the
  # suite's configured level.
  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    CodexPoolerWeb.RequestLogger.attach()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  describe "an all-exhausted Pool" do
    for path <- @native_http_paths do
      @path path

      test "native http #{path}: Codex Desktop gets the 400 invalid_prompt with the Pool's reset in the message; the row keeps the 429 refusal" do
        setup = exhausted_pool!()
        port = start_public_endpoint!()

        {response, log} = with_log([level: :info], fn -> post!(port, setup, @path, @desktop, native_http_body(@path, setup)) end)

        assert response.status == 400
        assert %{"error" => error} = CodexPooler.JSON.decode!(response.body)
        seconds = assert_desktop_answer!(error, DateTime.to_unix(setup.reset_at))
        assert seconds in (@reset_seconds - 5)..@reset_seconds
        assert Req.Response.get_header(response, "x-should-retry") == ["false"]
        assert Req.Response.get_header(response, "retry-after") == []
        assert_refused_row!(setup, error)
        assert log =~ ~r/request_completed method=POST path=#{Regex.escape(@path)} status=400 .*resets_at=#{error["resets_at"]} resets_in_seconds=#{seconds}/
      end
    end

    for originator <- @other_originators do
      @originator originator

      test "native http sse, originator #{inspect(originator)}: the 429 usage_limit_reached answer is unchanged" do
        setup = exhausted_pool!()
        port = start_public_endpoint!()

        response = post!(port, setup, @turn_path, @originator)

        assert response.status == 429
        assert %{"error" => error} = CodexPooler.JSON.decode!(response.body)
        seconds = assert_pool_answer!(error, DateTime.to_unix(setup.reset_at))
        assert Req.Response.get_header(response, "retry-after") == [Integer.to_string(seconds)]
        assert Req.Response.get_header(response, "x-should-retry") == ["false"]
        assert_refused_row!(setup, error)
      end
    end

    for forwarding <- [:off, :on], path <- @native_websocket_paths do
      @forwarding forwarding
      @path path

      test "native websocket #{path}, owner forwarding #{forwarding}: Codex Desktop gets the 400 invalid_prompt event; the row and the turn line keep the 429 refusal" do
        put_owner_forwarding!(@forwarding == :on)
        setup = exhausted_pool!()
        port = start_public_endpoint!()

        {event, log} =
          with_log([level: :info], fn ->
            event = websocket_turn!(port, setup, @path, @desktop)
            _rows = settled_rows!(setup)
            event
          end)

        assert %{"type" => "error", "status" => 400, "error" => error} = event
        refute Map.has_key?(event, "headers")
        seconds = assert_desktop_answer!(error, DateTime.to_unix(setup.reset_at))
        assert_refused_row!(setup, error)
        assert log =~ ~r/websocket native turn failed .*error_code=quota_exhausted .*resets_at=#{error["resets_at"]} resets_in_seconds=#{seconds}/
      end
    end

    for forwarding <- [:off, :on] do
      @forwarding forwarding

      test "native websocket, owner forwarding #{forwarding}: codex-tui keeps the wrapped 429 usage_limit_reached event" do
        put_owner_forwarding!(@forwarding == :on)
        setup = exhausted_pool!()
        port = start_public_endpoint!()

        assert %{"type" => "error", "status" => 429, "error" => error, "headers" => headers} = websocket_turn!(port, setup, @turn_path, "codex-tui")
        seconds = assert_pool_answer!(error, DateTime.to_unix(setup.reset_at))
        assert headers == %{"retry-after" => Integer.to_string(seconds)}
        assert_refused_row!(setup, error)
      end
    end

    test "/v1/responses over http: Codex Desktop keeps the 429 usage_limit_reached answer" do
      setup = exhausted_pool!()
      port = start_public_endpoint!()

      response = post!(port, setup, "/v1/responses", @desktop, %{"model" => setup.model.exposed_model_id, "input" => "synthetic prompt", "stream" => true})

      assert response.status == 429
      assert %{"error" => error} = CodexPooler.JSON.decode!(response.body)
      assert_pool_answer!(error, DateTime.to_unix(setup.reset_at))
    end

    for forwarding <- [:off, :on] do
      @forwarding forwarding

      test "/v1/responses over websocket, owner forwarding #{forwarding}: Codex Desktop keeps the wrapped 429 usage_limit_reached event" do
        put_owner_forwarding!(@forwarding == :on)
        setup = exhausted_pool!()
        port = start_public_endpoint!()

        frame = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => "synthetic prompt", "stream" => true}
        assert %{"type" => "error", "status" => 429, "error" => error, "headers" => %{"retry-after" => _seconds}} = websocket_turn!(port, setup, "/v1/responses", @desktop, frame)
        assert_pool_answer!(error, DateTime.to_unix(setup.reset_at))
      end
    end
  end

  describe "a Pool whose return is not known" do
    test "native http sse: Codex Desktop keeps the retryable 503" do
      setup = resetless_pool!()
      port = start_public_endpoint!()

      response = post!(port, setup, @turn_path, @desktop)

      assert response.status == 503
      assert %{"error" => %{"type" => "server_error", "code" => code} = error} = CodexPooler.JSON.decode!(response.body)
      assert code in ["quota_evidence_unavailable", "quota_exhausted"]
      refute Map.has_key?(error, "resets_at")
    end

    test "native websocket: Codex Desktop keeps the retryable 503 event" do
      put_owner_forwarding!(false)
      setup = resetless_pool!()
      port = start_public_endpoint!()

      assert %{"type" => "error", "status" => 503, "error" => %{"type" => "server_error"} = error} = websocket_turn!(port, setup, @turn_path, @desktop)
      refute Map.has_key?(error, "resets_at")
    end
  end

  describe "the last candidate's provider usage limit" do
    test "native http sse: Codex Desktop gets the 400 invalid_prompt with the Pool's reset in the message" do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @provider_reset_seconds
      upstream = start_upstream({:json_headers, 429, %{"error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at}}, [{"x-codex-rate-limit-reached-type", "workspace_member_usage_limit_reached"}]})
      setup = gateway_setup(upstream)
      port = start_public_endpoint!()

      response = post!(port, setup, @turn_path, @desktop)

      assert response.status == 400
      assert %{"error" => error} = CodexPooler.JSON.decode!(response.body)
      seconds = assert_desktop_answer!(error, resets_at)
      assert seconds in (@provider_reset_seconds - 5)..@provider_reset_seconds
      refute response.body =~ "synthetic provider text"
      assert [row] = settled_rows!(setup)
      assert {row.response_status_code, row.last_error_code} == {429, "upstream_rate_limited"}
      assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^row.id))
      assert attempt.response_metadata["usage_limit"] == Map.take(error, ["resets_at", "resets_in_seconds"])
    end

    for forwarding <- [:off, :on] do
      @forwarding forwarding

      test "native websocket, owner forwarding #{forwarding}: Codex Desktop gets the 400 invalid_prompt event for the provider's wrapped 429 frame" do
        put_owner_forwarding!(@forwarding == :on)
        resets_at = DateTime.to_unix(DateTime.utc_now()) + @provider_reset_seconds
        upstream = start_upstream(FakeUpstream.websocket_text_frames([provider_usage_limit_frame(resets_at)]))
        setup = gateway_setup(upstream)
        port = start_public_endpoint!()
        started_at = DateTime.utc_now()

        {event, log} =
          with_log([level: :info], fn ->
            event = websocket_turn!(port, setup, @turn_path, @desktop)
            _rows = settled_rows!(setup)
            event
          end)

        finished_at = DateTime.utc_now()

        assert %{"type" => "error", "status" => 400, "error" => error} = event
        refute Map.has_key?(event, "headers")
        assert_desktop_answer!(error, resets_at)
        refute CodexPooler.JSON.encode!(event) =~ "synthetic provider text"
        assert_provider_websocket_record!(setup, error, log, 400, {started_at, finished_at})
      end
    end

    test "/v1/responses over websocket: Codex Desktop keeps the wrapped 429 for the provider's frame, and the answered line says so" do
      put_owner_forwarding!(false)
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @provider_reset_seconds
      setup = gateway_setup(start_upstream(FakeUpstream.websocket_text_frames([provider_usage_limit_frame(resets_at)])))
      port = start_public_endpoint!()
      frame = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => "synthetic prompt", "stream" => true}
      started_at = DateTime.utc_now()

      {event, log} =
        with_log([level: :info], fn ->
          event = websocket_turn!(port, setup, "/v1/responses", @desktop, frame)
          _rows = settled_rows!(setup)
          event
        end)

      finished_at = DateTime.utc_now()

      assert %{"type" => "error", "status" => 429, "error" => error} = event
      seconds = assert_pool_answer!(error, resets_at)
      assert event["headers"] == %{"retry-after" => Integer.to_string(seconds)}
      assert_provider_websocket_record!(setup, error, log, 429, {started_at, finished_at})
    end

    test "native websocket: codex-tui's answered line names the 429 it was sent" do
      put_owner_forwarding!(false)
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @provider_reset_seconds
      setup = gateway_setup(start_upstream(FakeUpstream.websocket_text_frames([provider_usage_limit_frame(resets_at)])))
      port = start_public_endpoint!()
      started_at = DateTime.utc_now()

      {event, log} =
        with_log([level: :info], fn ->
          event = websocket_turn!(port, setup, @turn_path, "codex-tui")
          _rows = settled_rows!(setup)
          event
        end)

      finished_at = DateTime.utc_now()

      assert %{"type" => "error", "status" => 429, "error" => error} = event
      seconds = assert_pool_answer!(error, resets_at)
      assert event["headers"] == %{"retry-after" => Integer.to_string(seconds)}
      assert_provider_websocket_record!(setup, error, log, 429, {started_at, finished_at})
    end

    # A sibling taken out by an open circuit has no known return, so the Pool
    # advice is withheld and the refusal is relayed as the classified 429 to
    # every client, the Codex Desktop app included.
    test "native websocket: a withheld-advice relay stays the classified 429 for Codex Desktop, and its line says so" do
      put_owner_forwarding!(false)
      resets_at = DateTime.to_unix(DateTime.utc_now()) + @provider_reset_seconds
      setup = gateway_setup(start_upstream(FakeUpstream.websocket_text_frames([provider_usage_limit_frame(resets_at)])))
      sibling = gateway_upstream(setup.pool, start_upstream(FakeUpstream.json_response(%{"output" => []})), "upstream-token-desktop-sibling", compact?: false)
      setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])}
      open_circuit!(setup, sibling)
      port = start_public_endpoint!()

      {event, log} =
        with_log([level: :info], fn ->
          event = websocket_turn!(port, setup, @turn_path, @desktop)
          _rows = settled_rows!(setup)
          event
        end)

      assert %{"type" => "error", "status" => 429, "error" => %{"type" => "usage_limit_reached"}} = event
      assert log =~ ~r/websocket usage limit answered .*status=429 .*advice=withheld answered_status=429\n/
    end
  end

  # The originator is read on the socket's node only: by the socket, and by
  # its response task, which runs the dispatch attempt. Nothing that node
  # sends the session's owner on another VM carries it, so an owner of an
  # earlier release, which checks what it receives field by field, never meets
  # it in either direction of a rolling deploy (findings#270 row 270-261).
  describe "the originator across nodes" do
    @tag slow: "boots a second VM that owns the session and shares the committed database"
    test "never leaves the socket's node for the session's owner on another VM" do
      put_owner_forwarding!(true)
      enter_peer_owner_topology!()
      setup = gateway_setup(start_upstream(FakeUpstream.websocket_text_frames(served_turn_events())))
      thread = Ecto.UUID.generate()
      peer_owner = start_peer_window_owner!(setup, "#{thread}:0")
      port = start_public_endpoint!()
      marker = "synthetic-originator-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

      {terminal, crossings} = with_crossing_trace(fn -> traced_turn!(port, setup, thread, marker) end)

      assert %{"type" => "response.completed", "response" => %{"id" => "resp_desktop_served"}} = terminal
      assert node(peer_owner.owner_pid) != node()
      assert Enum.any?(crossings, &match?({:call, [_node, WebsocketOwnerForwarder, :remote_attach_downstream | _rest]}, &1))

      # The turn's submission leaves from the socket's response task, a
      # sensitive process no trace can observe here, so it is read where it
      # arrives: the peer traces its forwarder's entry (`start_bridge_peer!/3`).
      assert_receive {:remote_forwarder_v9_call, _pid, [_session_id, _downstream, _owner_request] = submission}, 15_000

      for crossing <- [{:received, :remote_submit_request_v9, submission} | crossings] do
        assert :binary.match(:erlang.term_to_binary(crossing), marker) == :nomatch, "the originator crossed: #{inspect(crossing, limit: 8)}"
      end
    end
  end

  # The Desktop displays only the message: the reset must remain visible in
  # UTC, but the surrounding sentence is not a wire contract.
  defp assert_desktop_answer!(error, resets_at) do
    assert %{"type" => "invalid_request_error", "code" => "invalid_prompt", "param" => nil, "resets_at" => ^resets_at, "resets_in_seconds" => seconds, "message" => message} = error
    assert error |> Map.keys() |> Enum.sort() == ~w(code message param resets_at resets_in_seconds type)
    assert is_integer(seconds) and seconds > 0
    assert message =~ reset_minute(resets_at)
    assert message =~ "UTC"
    seconds
  end

  defp assert_pool_answer!(error, resets_at) do
    assert %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "message" => message, "resets_at" => ^resets_at, "resets_in_seconds" => seconds} = error
    assert is_binary(message) and String.trim(message) != ""
    assert is_integer(seconds) and seconds > 0
    seconds
  end

  # The first minute that is not before the reset.
  defp reset_minute(resets_at), do: resets_at |> DateTime.from_unix!() |> DateTime.add(59, :second) |> Calendar.strftime("%H:%M")

  # The response task records and logs its projection; the socket projects the
  # same absolute reset later, potentially after a second boundary. Each
  # countdown must fit the observed interval, while the log must exactly match
  # the advice persisted on the attempt, not the socket's later countdown.
  defp assert_provider_websocket_record!(setup, error, log, answered_status, interval) do
    assert [row] = settled_rows!(setup)
    assert {row.status, row.response_status_code, row.last_error_code} == {"failed", 429, "usage_limit_reached"}
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^row.id))
    assert {attempt.status, attempt.upstream_status_code} == {"failed", 429}
    assert %{"resets_at" => resets_at, "resets_in_seconds" => seconds} = record = attempt.response_metadata["usage_limit"]
    assert resets_at == error["resets_at"]
    assert_countdown_between!(record, interval)
    assert_countdown_between!(error, interval)

    assert [[metadata]] = Regex.scan(~r/websocket usage limit answered ([^\n]*)/, log, capture: :all_but_first)

    fields =
      Map.new(String.split(metadata), fn field ->
        [key, value] = String.split(field, "=", parts: 2)
        {key, value}
      end)

    assert fields == %{
             "request_id" => row.id,
             "status" => "429",
             "error_code" => "usage_limit_reached",
             "advice" => "pool",
             "resets_at" => Integer.to_string(resets_at),
             "resets_in_seconds" => Integer.to_string(seconds),
             "answered_status" => Integer.to_string(answered_status)
           }

    refute error["message"] =~ "synthetic provider text"
    refute log =~ "synthetic provider text"
  end

  # The production calculator truncates to milliseconds before rounding up to
  # seconds. Microsecond observations preserve those exact quantization bounds,
  # including sub-millisecond edges, without a fixed scheduling tolerance.
  defp assert_countdown_between!(%{"resets_at" => resets_at, "resets_in_seconds" => seconds}, {started_at, finished_at}) do
    assert is_integer(seconds) and seconds > 0
    reset_at = DateTime.from_unix!(resets_at)
    assert DateTime.diff(reset_at, started_at, :microsecond) >= (seconds - 1) * 1_000_000 + 1_000
    assert DateTime.diff(reset_at, finished_at, :microsecond) < seconds * 1_000_000 + 1_000
  end

  # The refused row records the 429 refusal and the reset its answer advised.
  defp assert_refused_row!(setup, error) do
    assert [row] = settled_rows!(setup)
    assert {row.status, row.response_status_code, row.last_error_code} == {"rejected", 429, "quota_exhausted"}
    assert Map.take(row.request_metadata["gateway_denial"], ["resets_at", "resets_in_seconds"]) == Map.take(error, ["resets_at", "resets_in_seconds"])
  end

  defp exhausted_pool! do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"output" => []})), quota?: false, compact?: true)
    reset_at = DateTime.utc_now() |> DateTime.add(@reset_seconds, :second) |> DateTime.truncate(:second)
    prime_exhausted_routing_quota!(setup.identity, %{reset_at: reset_at})
    Map.put(setup, :reset_at, reset_at)
  end

  defp resetless_pool! do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"output" => []})), quota?: false)
    prime_resetless_routing_quota!(setup.identity)
    setup
  end

  defp open_circuit!(setup, sibling) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- ["proxy_websocket", "proxy_stream", "proxy_http"] do
      Repo.insert!(%CodexPooler.Gateway.Persistence.RoutingCircuitState{
        pool_id: setup.pool.id,
        pool_upstream_assignment_id: sibling.assignment.id,
        upstream_identity_id: sibling.identity.id,
        model_identifier: setup.model.exposed_model_id,
        route_class: route_class,
        status: "open",
        reason_code: "upstream_5xx",
        failure_count: 3,
        success_count: 0,
        opened_at: now,
        last_failure_at: now,
        next_probe_at: DateTime.add(now, 60, :second),
        metadata: %{"probe_in_flight_count" => 0},
        created_at: now,
        updated_at: now
      })
    end
  end

  defp provider_usage_limit_frame(resets_at) do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 429,
      "error" => %{"type" => "usage_limit_reached", "message" => "synthetic provider text", "resets_at" => resets_at, "resets_in_seconds" => @provider_reset_seconds},
      "headers" => %{"x-codex-rate-limit-reached-type" => "rate_limit_reached"}
    })
  end

  defp post!(port, setup, path, originator, body \\ nil) do
    thread = Ecto.UUID.generate()
    body = body || native_body(setup, thread)

    Req.post!("http://127.0.0.1:#{port}#{path}",
      headers: [{"authorization", setup.authorization}, {"content-type", "application/json"}, {"accept", "text/event-stream"} | client_headers(originator, thread)],
      body: CodexPooler.JSON.encode!(body),
      retry: false,
      decode_body: false,
      receive_timeout: 15_000
    )
  end

  defp websocket_turn!(port, setup, path, originator, frame \\ nil) do
    thread = Ecto.UUID.generate()
    frame = frame || native_body(setup, thread) |> Map.put("type", "response.create")
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = [{"authorization", setup.authorization}, {"openai-beta", "responses_websockets=2026-02-06"}, {"x-codex-beta-features", "remote_compaction_v2"} | client_headers(originator, thread)]
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(frame))
      receive_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> terminal
      _progress -> receive_terminal!(conn, websocket, ref)
    end
  end

  # The Codex session headers, and the client's own `originator` and
  # `user-agent` (a client with neither sends only an agent of its own).
  defp client_headers(originator, thread) do
    session = session_headers(thread)

    case originator do
      nil -> [{"user-agent", "synthetic-sdk/1.0"} | session]
      @desktop -> [{"originator", @desktop}, {"user-agent", @desktop_user_agent} | session]
      originator -> [{"originator", originator}, {"user-agent", "#{originator}/0.158.0 (Mac OS 27.0.0; arm64) unknown (#{originator}; 0.158.0)"} | session]
    end
  end

  defp session_headers(thread), do: [{"session-id", thread}, {"thread-id", thread}, {"x-client-request-id", thread}, {"x-codex-window-id", "#{thread}:0"}]

  # A compaction request carries its model and input only.
  defp native_http_body(path, setup) do
    if String.ends_with?(path, "/compact"),
      do: %{"model" => setup.model.exposed_model_id, "input" => native_text_input("synthetic compaction input")},
      else: native_body(setup, Ecto.UUID.generate())
  end

  defp native_body(setup, thread) do
    %{
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic prompt"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true,
      "prompt_cache_key" => thread,
      "client_metadata" => %{"session_id" => thread, "thread_id" => thread, "turn_id" => Ecto.UUID.generate()}
    }
  end

  defp settled_rows!(setup) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at])) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        rows != [] and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  # Every call a process of this node makes to another node (`:erpc.call/5`)
  # and every message it sends a process there, until `fun` returned and its
  # socket was cleaned up; the trace is removed afterwards. A sensitive
  # process (the response task, the upstream and owner sessions) is not
  # traced.
  defp with_crossing_trace(fun) do
    remote_receiver = [
      {[:"$1", :_], [{:is_pid, :"$1"}, {:"=/=", {:node, :"$1"}, {:node}}], []},
      {[{:_, :"$1"}, :_], [{:is_atom, :"$1"}, {:"=/=", :"$1", {:node}}], []}
    ]

    _count = :erlang.trace_pattern({:erpc, :call, 5}, true, [:global])
    _count = :erlang.trace_pattern(:send, remote_receiver, [])
    _count = :erlang.trace(:processes, true, [:call, :send, {:tracer, self()}])

    result =
      try do
        fun.()
      after
        _count = :erlang.trace(:processes, false, [:call, :send])
        _count = :erlang.trace_pattern({:erpc, :call, 5}, false, [:global])
        _count = :erlang.trace_pattern(:send, true, [])
      end

    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 15_000
    {result, drain_crossings([])}
  end

  defp drain_crossings(crossings) do
    receive do
      {:trace, _pid, :call, {:erpc, :call, args}} -> drain_crossings([{:call, args} | crossings])
      {:trace, _pid, :send, message, to} when is_pid(to) and node(to) != node() -> drain_crossings([{:send, to, message} | crossings])
      {:trace, _pid, :send, message, {_name, to_node} = to} when to_node != node() -> drain_crossings([{:send, to, message} | crossings])
      {:trace, _pid, :send, _message, _local} -> drain_crossings(crossings)
    after
      0 -> Enum.reverse(crossings)
    end
  end

  # One served native turn on its own socket, waited for until the socket's
  # cleanup (and its owner detach) is done.
  defp traced_turn!(port, setup, thread, originator) do
    before = WebsocketCleanupFence.listener_sockets()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = [{"authorization", setup.authorization}, {"openai-beta", "responses_websockets=2026-02-06"}, {"originator", originator}, {"user-agent", "synthetic-client/1.0"} | session_headers(thread)]
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_path, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(Map.put(native_body(setup, thread), "type", "response.create")))
    terminal = receive_terminal!(conn, websocket, ref)
    _rows = settled_rows!(setup)
    Mint.HTTP.close(conn)
    :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(socket)
    terminal
  end

  defp served_turn_events do
    item = %{"type" => "message", "id" => "msg_desktop_served", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => "resp_desktop_served", "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => "resp_desktop_served", "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end
end
