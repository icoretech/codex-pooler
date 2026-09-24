defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.TerminalPolicyDenialStatusTest do
  # An API key policy denial that the same request can never pass answers
  # `400 invalid_request_error` on every transport, and the refused row
  # records that status (findings#206 row 206-438):
  #
  # - `model_not_allowed`: the key's allowed models exclude the requested one.
  #   The Codex backend refuses a model the ChatGPT account cannot serve with
  #   `400` too (a detail body over HTTP, a codeless wrapped `400
  #   invalid_request_error` on the websocket; live probe, findings#232 row
  #   232-279), and the key's own `reasoning_effort_not_allowed` already
  #   answers `400`.
  #
  # The released client (Codex 0.156.1) maps a `400` to `InvalidRequest`,
  # which ends the turn at once (`codex-rs/codex-api/src/api_bridge.rs`,
  # `codex-rs/protocol/src/error.rs` `retry_delay`). The `403` answered before
  # is `UnexpectedStatus`: the client resent the refused turn five times,
  # then switched the session from websocket to HTTPS and resent it five more
  # times (`codex-rs/core/src/responses_retry.rs`).
  #
  # The per-request estimate caps are pinned in
  # `reservation_policy_refusal_status_test.exs`.
  #
  # One node, native websocket (owner forwarding on and off) and HTTP SSE,
  # Full, FakeUpstream, the released client's key sets, synthetic text.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @installation_id "00000000-0000-4000-8000-00000000c438"
  @turn_endpoint "/backend-api/codex/responses"

  @model_not_allowed %{status: 400, code: "model_not_allowed", type: "invalid_request_error", param: "model", message: "api key is not allowed to use this model"}

  # `released_turn` is the frame the released client sends for every turn:
  # its `x-codex-turn-metadata` makes it replay-eligible, so with owner
  # forwarding on the owner's replay preflight refuses it, a path the bare
  # frame never reaches (the replay preflight recorded no row, findings#206,
  # S18 2026-09-24; pinned per refusal in
  # `replay_preflight_policy_denial_record_test.exs`).
  for forwarding <- [:forwarded, :direct], shape <- [:bare, :released_turn] do
    @tag forwarding: forwarding, shape: shape
    test "websocket #{forwarding} #{shape}: a model the key may not use is refused 400 and recorded 400", %{forwarding: forwarding, shape: shape} do
      put_owner_forwarding!(forwarding)
      thread_id = Ecto.UUID.generate()
      upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
      setup = gateway_setup(upstream, compact?: true)
      {_server, port} = start_public_endpoint_with_server!()
      forbid_model!(setup)

      terminal = send_once!(port, setup, thread_id, shape)
      rows = await_settled!(setup.pool.id, 1)

      measured = %{
        refused: denial_of(terminal),
        rows: Enum.map(rows, &{&1.status, &1.last_error_code, &1.response_status_code}),
        upstream_requests: FakeUpstream.count(upstream)
      }

      CodexPooler.TestDiagnostics.puts(fn -> "206-438 websocket model_not_allowed #{forwarding} #{shape}: #{inspect(measured)}" end)

      assert measured == %{
               refused: {@model_not_allowed.status, Map.drop(@model_not_allowed, [:status])},
               rows: [{"rejected", @model_not_allowed.code, @model_not_allowed.status}],
               upstream_requests: 0
             }
    end
  end

  test "http sse: a model the key may not use is refused 400 and recorded 400", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream, compact?: true)
    forbid_model!(setup)

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("content-type", "application/json")
      |> post(@turn_endpoint, CodexPooler.JSON.encode!(http_body(setup)))

    rows = await_settled!(setup.pool.id, 1)

    measured = %{
      refused: {conn.status, error_fields(CodexPooler.JSON.decode!(conn.resp_body))},
      rows: Enum.map(rows, &{&1.status, &1.last_error_code, &1.response_status_code}),
      upstream_requests: FakeUpstream.count(upstream)
    }

    CodexPooler.TestDiagnostics.puts(fn -> "206-438 http model_not_allowed: #{inspect(measured)}" end)

    assert measured == %{
             refused: {@model_not_allowed.status, Map.drop(@model_not_allowed, [:status])},
             rows: [{"rejected", @model_not_allowed.code, @model_not_allowed.status}],
             upstream_requests: 0
           }
  end

  test "the compatibility matrix names the status measured here" do
    fixture = CodexPooler.CompatibilityMatrix.fixture!(:api_key_terminal_policy_denials)

    assert fixture.model_not_allowed == %{status: 400, type: "invalid_request_error", param: "model"}
    assert fixture.request_cap == %{status: 400, type: "invalid_request_error", code: "api_key_policy_limit_exceeded"}
    assert fixture.image_generation_disabled == %{status: 403, type: "invalid_request_error", routes: :http_image_routes_only}
    assert fixture.recorded_status == :answered_status
  end

  defp forbid_model!(setup) do
    setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: ["another-model-fixture"])
    |> Repo.update!()

    :ok
  end

  defp denial_of(%{"type" => "error", "status" => status, "error" => error}), do: {status, error_fields(%{"error" => error})}
  defp denial_of(other), do: {:not_refused, other["type"]}

  defp error_fields(%{"error" => error}) do
    %{code: error["code"], type: error["type"], param: error["param"], message: error["message"]}
  end

  # One request on its own connection, as the released client sends a turn.
  defp send_once!(port, setup, thread_id, shape) do
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
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, thread_id, shape))
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

  defp frame(setup, thread_id, shape) do
    turn_id = "#{thread_id}-turn"

    %{
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
      "prompt_cache_key" => thread_id,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => turn_id,
        "root_turn_id" => turn_id,
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => "#{thread_id}:0"
      }
    }
    |> put_turn_metadata(shape, thread_id, turn_id)
    |> CodexPooler.JSON.encode!()
  end

  defp put_turn_metadata(frame, :bare, _thread_id, _turn_id), do: frame

  defp put_turn_metadata(frame, :released_turn, thread_id, turn_id) do
    metadata = %{
      "agent_name" => "/root",
      "installation_id" => @installation_id,
      "request_kind" => "turn",
      "root_turn_id" => turn_id,
      "session_id" => thread_id,
      "thread_id" => thread_id,
      "turn_id" => turn_id,
      "window_id" => "#{thread_id}:0",
      "window_number" => 0,
      "model" => frame["model"],
      "reasoning_effort" => "low"
    }

    put_in(frame, ["client_metadata", "x-codex-turn-metadata"], CodexPooler.JSON.encode!(metadata))
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

  defp prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic policy denial prompt"}]}

  # The socket writes the terminal before its task settles the row; poll the
  # rows within a detection budget.
  defp await_settled!(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at])) end)
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
