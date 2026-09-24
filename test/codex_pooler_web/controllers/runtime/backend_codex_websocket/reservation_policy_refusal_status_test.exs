defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ReservationPolicyRefusalStatusTest do
  # An API key's policy refuses a request at the reservation
  # (`ReservationPolicy`, `api_key_policy_limit_exceeded`) in two families:
  #
  # - a window (requests per minute, tokens per day, tokens per week) that
  #   admits the request again once it moves: `429` with the rate-limit type,
  #   like the key's active-request cap, and a retry hint derived from the
  #   window's own boundary where it has one (HTTP `Retry-After`, the websocket
  #   error's `headers`): the minute window turns over within 60 s, the daily
  #   one restarts at 00:00 UTC, the trailing week has no boundary of its own,
  #   so no hint; on HTTP a window that frees no sooner than a minute also
  #   says `x-should-retry: false`;
  # - a per-request estimate cap (input or output tokens) that no resend of the
  #   same request can pass: `400 invalid_request_error`, which the released
  #   client ends the turn on; the `403` answered before made it resend the
  #   refused turn five times and fall back to HTTPS (findings#206 row 206-438);
  # - a token window (daily or weekly) whose max is below the request's own
  #   estimate: no later window admits that request either, so it is the same
  #   per-request `400` with no hint, not a `429` promising the next 00:00 UTC
  #   (findings#206 row 206-448). A window refusal is one the request fits once
  #   the window moves: the token windows here are exhausted by an earlier
  #   request still holding its reservation.
  #
  # The websocket answered every one of them `500` (the refusal carried no
  # status and the socket renders a missing status as a server fault, which
  # the released client (Codex 0.156.1) retries and then falls back to HTTPS
  # for); HTTP answered `403` for all of them and the refused row recorded
  # `400` on both transports (findings#206 row 206-427).
  #
  # With owner forwarding on, the owner's client-retry successor claim turned
  # every such refusal into `409 duplicate_turn` and recorded no refused row
  # (row 206-428): a chained resend now gets the same refusal, recorded the
  # same way, with forwarding on and off. An open circuit's
  # `no_eligible_backend` is refused at routing, before that claim, and already
  # answered alike; it is pinned here.
  #
  # One node, native websocket and HTTP SSE, Full, owner forwarding on and
  # off, FakeUpstream, the released client's key sets, synthetic text.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPooler.AccountingTestSupport, only: [hold_key_reservation!: 4, release_key_reservation!: 1]

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @installation_id "00000000-0000-4000-8000-00000000c427"
  @context_window_id "00000000-0000-4000-8000-00000000c428"
  @turn_endpoint "/backend-api/codex/responses"
  @code "api_key_policy_limit_exceeded"

  # limit => {status, HTTP retry hint}
  @limits %{
    requests_per_minute: {429, :minute},
    tokens_per_day: {429, :daily},
    tokens_per_week: {429, nil},
    input_tokens_per_request: {400, nil},
    output_tokens_per_request: {400, nil},
    request_above_tokens_per_day: {400, nil},
    request_above_tokens_per_week: {400, nil}
  }

  @limit_names [
    :requests_per_minute,
    :tokens_per_day,
    :tokens_per_week,
    :input_tokens_per_request,
    :output_tokens_per_request,
    :request_above_tokens_per_day,
    :request_above_tokens_per_week
  ]

  # An earlier request of the key holds this many output tokens reserved; the
  # refused request's own estimate (a short prompt and the default output
  # reservation) fits under it alone.
  @holder_output_tokens 10_000

  for limit <- @limit_names, forwarding <- [:forwarded, :direct] do
    @tag limit: limit, forwarding: forwarding
    test "websocket #{forwarding}: a #{limit} refusal is answered and recorded with its own status", %{limit: limit, forwarding: forwarding} do
      {status, hint} = @limits[limit]
      measured = run_websocket_refusal(limit, forwarding)

      assert Map.delete(measured, :retry_after) == %{
               refused: {status, @code, error_type(status)},
               rows: [{"rejected", @code, status}],
               upstream_requests: 0
             }

      assert_retry_hint(measured.retry_after, hint)
    end
  end

  for limit <- @limit_names do
    @tag limit: limit
    test "http sse: a #{limit} refusal is answered and recorded with its own status and retry hint", %{conn: conn, limit: limit} do
      {status, hint} = @limits[limit]
      measured = run_http_refusal(conn, limit)

      assert Map.drop(measured, [:retry_after]) == %{
               refused: {status, @code, error_type(status)},
               should_retry: should_retry(status, hint),
               rows: [{"rejected", @code, status}],
               upstream_requests: 0
             }

      assert_retry_hint(measured.retry_after, hint)
    end
  end

  test "the compatibility matrix names the statuses and hints measured here" do
    fixture = CodexPooler.CompatibilityMatrix.fixture!(:api_key_reservation_policy_refusals)

    assert fixture.code == @code
    assert fixture.window.status == 429 and fixture.window.type == error_type(429)
    assert fixture.window.admits_request_once_moved == true
    assert fixture.request_cap.status == 400 and fixture.request_cap.type == error_type(400)
    assert fixture.request_cap.window_below_request_estimate == ["max_tokens_per_day", "max_tokens_per_week"]
    assert fixture.window.retry_after_seconds == %{minute: 60, daily: :until_next_utc_midnight, weekly: nil}
    assert fixture.window.http_x_should_retry == %{minute: nil, daily: "false", weekly: "false"}
    assert fixture.recorded_status == :answered_status
  end

  # 206-428: the resend of a provider-failed opening turn, refused at its
  # reservation. Forwarding off chains it under `codex-request-retry:` through
  # the ordinary reservation; forwarding on, under `client-retry-v1:` through
  # the owner's successor claim. Both answer and record the same refusal, and
  # the next resend chains onto the predecessor once the cause is lifted.
  for refusal <- [:tokens_per_day, :requests_per_minute, :open_circuit], forwarding <- [:forwarded, :direct] do
    @tag refusal: refusal, forwarding: forwarding
    test "#{forwarding}: a chained resend refused by #{refusal} gets the refusal forwarding off gives, recorded", %{refusal: refusal, forwarding: forwarding} do
      {status, code} = if refusal == :open_circuit, do: {503, "no_eligible_backend"}, else: {elem(@limits[refusal], 0), @code}
      successor_claim = if forwarding == :forwarded, do: "client-retry-v1:", else: "codex-request-retry:"

      assert run_chained_refusal(refusal, forwarding) == %{
               predecessor: {"failed", "server_error"},
               refused: {status, code},
               refused_row: {"rejected", code, status, :unclaimed, :unlinked},
               retry: :served,
               successor: {"succeeded", successor_claim, :chained},
               upstream_requests: 2,
               live_rows: 0
             }
    end
  end

  defp run_websocket_refusal(limit, forwarding) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()

    impose_limit!(limit, setup)
    terminal = send_once!(port, setup, thread_id, frame(setup, thread_id))
    rows = await_settled!(setup.pool.id, 1, &websocket?/1)
    {status, code} = refusal_of(terminal)

    # The released client reads a wrapped error's `headers` as the response
    # headers of the refusal.
    measured = %{
      refused: {status, code, get_in(terminal, ["error", "type"])},
      retry_after: get_in(terminal, ["headers", "retry-after"]),
      rows: Enum.map(rows, &{&1.status, &1.last_error_code, &1.response_status_code}),
      upstream_requests: FakeUpstream.count(upstream)
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-427 websocket #{limit} #{forwarding}: #{inspect(measured)}" end)
    measured
  end

  defp run_http_refusal(conn, limit) do
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream, compact?: true)
    impose_limit!(limit, setup)

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("content-type", "application/json")
      |> post(@turn_endpoint, CodexPooler.JSON.encode!(http_body(setup)))

    %{"error" => %{"code" => code, "type" => type}} = CodexPooler.JSON.decode!(conn.resp_body)
    rows = await_settled!(setup.pool.id, 1, &(&1.transport != "websocket"))

    measured = %{
      refused: {conn.status, code, type},
      retry_after: conn |> Plug.Conn.get_resp_header("retry-after") |> List.first(),
      should_retry: conn |> Plug.Conn.get_resp_header("x-should-retry") |> List.first(),
      rows: Enum.map(rows, &{&1.status, &1.last_error_code, &1.response_status_code}),
      upstream_requests: FakeUpstream.count(upstream)
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-427 http #{limit}: #{inspect(measured)}" end)
    measured
  end

  defp run_chained_refusal(refusal, forwarding) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create"}], respond: provider_failure_frames()),
          served_expectation("resp_policy_refusal_chained")
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    frame = frame(setup, thread_id)

    assert %{"type" => "response.failed"} = send_once!(port, setup, thread_id, frame)
    [predecessor] = await_settled!(setup.pool.id, 1, &websocket?/1)

    # The predecessor's own admission is the minute window's one request.
    lifted = impose_refusal!(refusal, setup)
    refused = port |> send_once!(setup, thread_id, frame) |> refusal_of()
    refused_row = setup.pool.id |> await_settled!(2, &websocket?/1) |> Enum.find(&(&1.id != predecessor.id))
    lifted.()

    retry = port |> send_once!(setup, thread_id, frame) |> outcome()
    rows = await_settled!(setup.pool.id, 3, &websocket?/1)
    predecessor_now = Repo.get(Request, predecessor.id)
    successor = Enum.find(rows, &(&1.id != predecessor.id and &1.status == "succeeded"))

    measured = %{
      predecessor: {predecessor_now.status, predecessor_now.last_error_code},
      refused: refused,
      refused_row:
        refused_row &&
          {refused_row.status, refused_row.last_error_code, refused_row.response_status_code, claim_state(refused_row.correlation_id), if(linked?(refused_row), do: :linked, else: :unlinked)},
      retry: retry,
      successor: successor && {successor.status, claim_prefix(successor.correlation_id), if(chained?(successor, predecessor), do: :chained, else: :unchained)},
      upstream_requests: FakeUpstream.count(upstream),
      live_rows: Enum.count(rows, &(&1.status in ["accepted", "in_progress"]))
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-428 chained #{refusal} #{forwarding}: #{inspect(measured)}" end)
    if retry == :served, do: assert(:ok = FakeUpstream.verify!(upstream))
    measured
  end

  # One committed admission of the key inside the minute window.
  defp impose_limit!(:requests_per_minute, setup) do
    {:ok, auth} = CodexPooler.Access.authenticate_authorization_header(setup.authorization)

    {:ok, %{request: holder}} =
      Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10}, %{correlation_id: "policy-refusal-holder-#{System.unique_integer([:positive])}"})

    {:ok, _settled} =
      Accounting.finalize_reserved_request_failure(holder, %{request_status: "failed", response_status_code: 499, last_error_code: "client_disconnected", usage_status: "not_applicable"})

    put_policy!(setup, max_requests_per_minute: 1)
  end

  defp impose_limit!(:tokens_per_day, setup) do
    hold_key_reservation!(setup.authorization, setup.model, @holder_output_tokens, "policy-refusal-holder")
    put_policy!(setup, max_tokens_per_day: @holder_output_tokens)
  end

  defp impose_limit!(:tokens_per_week, setup) do
    hold_key_reservation!(setup.authorization, setup.model, @holder_output_tokens, "policy-refusal-holder")
    put_policy!(setup, max_tokens_per_week: @holder_output_tokens)
  end

  defp impose_limit!(:request_above_tokens_per_day, setup), do: put_policy!(setup, max_tokens_per_day: 1)
  defp impose_limit!(:request_above_tokens_per_week, setup), do: put_policy!(setup, max_tokens_per_week: 1)
  defp impose_limit!(:input_tokens_per_request, setup), do: put_policy!(setup, max_input_tokens_per_request: 1)
  defp impose_limit!(:output_tokens_per_request, setup), do: put_policy!(setup, max_output_tokens_per_request: 1)

  defp impose_refusal!(:open_circuit, setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    circuits =
      for route_class <- [CodexPooler.RouteClass.proxy_websocket(), CodexPooler.RouteClass.proxy_stream(), CodexPooler.RouteClass.proxy_http()],
          model_identifier <- Enum.uniq([setup.model.upstream_model_id, setup.model.exposed_model_id]) do
        Repo.insert!(%RoutingCircuitState{
          pool_id: setup.pool.id,
          pool_upstream_assignment_id: setup.assignment.id,
          upstream_identity_id: setup.assignment.upstream_identity_id,
          model_identifier: model_identifier,
          route_class: route_class,
          status: "open",
          reason_code: "synthetic_circuit_reason",
          failure_count: 3,
          success_count: 0,
          opened_at: now,
          next_probe_at: DateTime.add(now, 3_600, :second),
          last_failure_at: now,
          metadata: %{},
          created_at: now,
          updated_at: now
        })
      end

    fn -> Enum.each(circuits, &Repo.delete!/1) end
  end

  defp impose_refusal!(:requests_per_minute, setup) do
    put_policy!(setup, max_requests_per_minute: 1)
    fn -> put_policy!(setup, max_requests_per_minute: nil) end
  end

  defp impose_refusal!(:tokens_per_day, setup) do
    holder = hold_key_reservation!(setup.authorization, setup.model, @holder_output_tokens, "policy-refusal-holder")
    put_policy!(setup, max_tokens_per_day: @holder_output_tokens)

    fn ->
      release_key_reservation!(holder)
      put_policy!(setup, max_tokens_per_day: nil)
    end
  end

  defp put_policy!(setup, set) do
    {1, _} = Repo.update_all(from(binding in APIKeyPolicyBinding, where: binding.api_key_id == ^setup.api_key.id), set: [status: "active"] ++ set)
    :ok
  end

  defp assert_retry_hint(value, nil), do: assert(value == nil)
  defp assert_retry_hint(value, :minute), do: assert(value == "60")

  # The daily window restarts at the next 00:00 UTC.
  defp assert_retry_hint(value, :daily) do
    now = DateTime.utc_now()
    midnight = now |> DateTime.to_date() |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    expected = DateTime.diff(midnight, now)

    assert is_binary(value), "no retry-after header"
    assert {seconds, ""} = Integer.parse(value)
    assert seconds in max(expected - 5, 1)..(expected + 5)
  end

  # The OpenAI SDKs retry every 429 twice within seconds when its hint exceeds
  # their ceiling (60 s in openai-node, 120 s in openai-python); a window that
  # frees no sooner than that says not to.
  defp should_retry(429, :minute), do: nil
  defp should_retry(429, _hint), do: "false"
  defp should_retry(_status, _hint), do: nil

  defp error_type(429), do: "rate_limit_error"
  defp error_type(_status), do: "invalid_request_error"

  # One request on its own connection, as the released client sends a retry:
  # a new connection and the same body.
  defp send_once!(port, setup, thread_id, frame) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
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

  defp refusal_of(%{"type" => "error", "status" => status, "error" => %{"code" => code}}), do: {status, code}
  defp refusal_of(other), do: {:not_refused, other["type"]}

  defp outcome(%{"type" => "response.completed"}), do: :served
  defp outcome(terminal), do: refusal_of(terminal)

  defp served_expectation(response_id) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
      respond: completed_frames(response_id)
    )
  end

  defp frame(setup, thread_id) do
    turn_id = "#{thread_id}-turn"

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => [prompt()],
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "text" => %{"verbosity" => "low"},
      "prompt_cache_key" => thread_id,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => turn_id,
        "root_turn_id" => turn_id,
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => "#{thread_id}:0",
        "x-codex-turn-metadata" => turn_metadata(thread_id, turn_id)
      }
    })
  end

  defp http_body(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => [prompt()],
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true
    }
  end

  defp turn_metadata(thread_id, turn_id) do
    CodexPooler.JSON.encode!(%{
      "agent_name" => "/root",
      "context_window_id" => @context_window_id,
      "installation_id" => @installation_id,
      "root_turn_id" => turn_id,
      "sandbox" => "seatbelt",
      "sandbox_mode" => "read-only",
      "session_id" => thread_id,
      "thread_id" => thread_id,
      "turn_id" => turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "window_id" => "#{thread_id}:0",
      "window_number" => 0,
      "model" => "gpt-test-model",
      "reasoning_effort" => "low",
      "request_kind" => "turn"
    })
  end

  defp prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic policy refusal prompt"}]}
  defp answer, do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}
  defp usage, do: %{"input_tokens" => 20, "output_tokens" => 2, "total_tokens" => 22}

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => answer()}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [answer()], "usage" => usage()}})
    ])
  end

  # provenance: observed runbook terminal-failure resend (response.failed server_error)
  defp provider_failure_frames do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => "resp_policy_refusal_failed", "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{"type" => "response.failed", "response" => %{"id" => "resp_policy_refusal_failed", "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic provider failure"}}})
    ])
  end

  # A refused row never holds a request claim: its correlation is a generated
  # id or the socket's handshake request id.
  defp claim_state(claim) do
    case claim_prefix(claim) do
      nil -> :unclaimed
      prefix -> {:holds, prefix}
    end
  end

  defp claim_prefix(claim) when is_binary(claim) do
    Enum.find(["client-retry-v1:", "codex-request-retry:", "codex-turn:", "codex-request:", "codex-resume:"], &String.starts_with?(claim, &1))
  end

  defp claim_prefix(_claim), do: nil

  defp websocket?(%Request{transport: transport}), do: transport == "websocket"

  defp linked?(%Request{id: id}), do: Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^id or link.predecessor_request_id == ^id))

  defp chained?(%Request{id: successor_id}, %Request{id: predecessor_id}),
    do: Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^successor_id and link.predecessor_request_id == ^predecessor_id))

  defp pool_requests(pool_id, filter),
    do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id and not like(request.correlation_id, "policy-refusal-holder-%"), order_by: [asc: request.admitted_at, asc: request.id])) |> Enum.filter(filter)

  # The socket writes the terminal before the task, or the socket's cleanup,
  # settles its rows; poll the rows within a detection budget.
  defp await_settled!(pool_id, count, filter) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> pool_requests(pool_id, filter) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) and no_live_attempt?(rows) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp no_live_attempt?(rows) do
    ids = Enum.map(rows, & &1.id)
    not Repo.exists?(from(attempt in Attempt, where: attempt.request_id in ^ids and attempt.status in ["queued", "in_progress"]))
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
