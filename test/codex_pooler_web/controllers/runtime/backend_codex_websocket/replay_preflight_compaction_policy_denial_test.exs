defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ReplayPreflightCompactionPolicyDenialTest do
  # A released client's in-band compaction frame carries
  # `x-codex-turn-metadata` with `request_kind: compaction`, which makes it
  # replay-eligible like a turn frame. A compaction for a model the key may
  # not use must leave what the turn frame's refusal leaves (findings#206 rows
  # 206-535, 206-540 and 206-542; turn frames are pinned in
  # `replay_preflight_policy_denial_record_test.exs` and
  # `replay_preflight_denial_row_parity_test.exs`): the `400 model_not_allowed`
  # frame, one `rejected 400` row on the compaction endpoint carrying the
  # requested and effective model, the same row on both forwarding modes, one
  # refusal line, and nothing sent upstream.
  #
  # Two shapes the released client sends:
  # - `full_history`: the whole history and the trigger with no anchor, as it
  #   is sent on a new socket. With owner forwarding on the owner's replay
  #   preflight refuses it and logs `runtime_replay_preflight`.
  # - `anchored`: a pre-turn compaction on the socket that served the previous
  #   turn, anchored on that turn's response, for the model the user switched
  #   to (the key allows only the first one). It never reaches the owner's
  #   replay preflight, on either forwarding mode: a bounded probe at
  #   `CodexResponsesSocket.dispatch_owner_prepared_response/2`,
  #   `attach_queued_owner_replay_intent/2` and the preflight saw only the
  #   first turn. The fresh path refuses it and the socket logs
  #   `websocket native turn failed`.
  #
  # One node, native websocket with owner forwarding on and off, the Pool's
  # serving mode forced to Full and to Lite for both models, FakeUpstream,
  # synthetic text.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @installation_id "00000000-0000-4000-8000-00000000c542"
  @context_window_id "00000000-0000-4000-8000-00000000c543"
  @turn_endpoint "/backend-api/codex/responses"
  @switched_model "gpt-switched-fixture-model"

  for shape <- [:anchored, :full_history], forwarding <- [:forwarded, :direct], mode <- ["full", "lite"] do
    @tag shape: shape, forwarding: forwarding, serving_mode: mode
    test "websocket #{forwarding} #{mode}: the #{shape} compaction frame for a model the key may not use is refused, recorded and logged once", %{shape: shape, forwarding: forwarding, serving_mode: mode} do
      measured = run_refusal(shape, forwarding, mode)

      assert measured.refused == {400, "model_not_allowed", "invalid_request_error", "model"}
      assert measured.upstream_requests == if(shape == :anchored, do: 1, else: 0)
      assert measured.served_before == if(shape == :anchored, do: [{"succeeded", nil}], else: [])

      assert Enum.map(measured.refusal_rows, &Map.delete(&1, :endpoint)) == [
               %{
                 status: "rejected",
                 last_error_code: "model_not_allowed",
                 response_status_code: 400,
                 transport: "websocket",
                 requested_model: @switched_model,
                 switched_model?: true,
                 metadata: %{"requested_model" => @switched_model, "effective_model" => @switched_model, "code" => "model_not_allowed"}
               }
             ]

      assert measured.logged == expected_log(shape, forwarding)
    end
  end

  # Both routes write the same refusal row for the same frame.
  for shape <- [:anchored, :full_history] do
    @tag shape: shape
    test "websocket full: the refusal row of the #{shape} compaction frame is the same on both forwarding modes", %{shape: shape} do
      forwarded = run_refusal(shape, :forwarded, "full")
      direct = run_refusal(shape, :direct, "full")

      assert forwarded.refusal_rows == direct.refusal_rows
    end
  end

  defp run_refusal(shape, forwarding, mode) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(upstream_behaviour(shape))
    setup = gateway_setup(upstream, compact?: true)
    switched = switched_model!(setup)
    put_serving_mode!(setup.pool, [setup.model.exposed_model_id, switched.exposed_model_id], mode)
    setup.api_key |> Ecto.Changeset.change(allowed_model_identifiers: [setup.model.exposed_model_id]) |> Repo.update!()
    {_server, port} = start_public_endpoint_with_server!()

    {terminal, log} = with_info_log(fn -> drive!(shape, port, setup, thread_id) end)
    rows = await_settled!(setup.pool.id, if(shape == :anchored, do: 2, else: 1))
    {refusal_rows, served_before} = Enum.split_with(rows, &(&1.status == "rejected"))

    measured = %{
      refused: denial_of(terminal),
      refusal_rows: Enum.map(refusal_rows, &project(&1, switched)),
      served_before: Enum.map(served_before, &{&1.status, &1.last_error_code}),
      upstream_requests: FakeUpstream.count(upstream),
      logged: logged(log)
    }

    CodexPooler.TestDiagnostics.puts(fn ->
      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/model_not_allowed|invalid_model/))
      "206-542 compaction #{shape} #{forwarding} #{mode}: #{inspect(measured)} log: #{inspect(lines)}"
    end)

    measured
  end

  # A second model the Pool serves from the same assignment, so the fresh path
  # sees it as visible and refuses it on the key's policy, as the preflight
  # does.
  defp switched_model!(setup) do
    metadata = setup.model.metadata |> CodexPooler.JSON.encode!() |> String.replace(setup.model.exposed_model_id, @switched_model) |> CodexPooler.JSON.decode!()

    CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{
      exposed_model_id: @switched_model,
      upstream_model_id: "provider-" <> @switched_model,
      display_name: "Switched fixture model",
      pricing_ref: "provider-" <> @switched_model,
      metadata: metadata
    })
  end

  defp project(row, switched) do
    %{
      status: row.status,
      last_error_code: row.last_error_code,
      response_status_code: row.response_status_code,
      transport: row.transport,
      endpoint: row.endpoint,
      requested_model: row.requested_model,
      switched_model?: row.model_id == switched.id,
      metadata:
        row.request_metadata
        |> Map.take(["requested_model", "effective_model"])
        |> Map.put("code", get_in(row.request_metadata, ["gateway_denial", "code"]))
    }
  end

  defp upstream_behaviour(:anchored), do: FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "WEBSOCKET", respond: completed_frames("resp_c542_first"))])
  defp upstream_behaviour(:full_history), do: FakeUpstream.json_response(%{"output" => []})

  # The first turn on the allowed model, then the pre-turn compaction for the
  # switched model on the same socket, anchored on the first turn's response.
  defp drive!(:anchored, port, setup, thread_id) do
    {conn, websocket, ref} = connect!(port, setup, thread_id)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, turn_frame(setup.model.exposed_model_id, thread_id))
      {conn, websocket, %{"type" => "response.completed"}} = receive_terminal_on!(conn, websocket, ref)
      await_settled!(setup.pool.id, 1)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, anchored_compaction_frame(thread_id, "resp_c542_first"))
      {_conn, _websocket, terminal} = receive_terminal_on!(conn, websocket, ref)
      terminal
    after
      Mint.HTTP.close(conn)
    end
  end

  defp drive!(:full_history, port, setup, thread_id) do
    {conn, websocket, ref} = connect!(port, setup, thread_id)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, full_history_compaction_frame(thread_id))
      {_conn, _websocket, terminal} = receive_terminal_on!(conn, websocket, ref)
      terminal
    after
      Mint.HTTP.close(conn)
    end
  end

  # Forwarding off, and for the anchored frame on either mode, the fresh path
  # refuses the frame and the socket logs the failed turn; forwarding on, the
  # owner's replay preflight refuses the unanchored frame and logs its line.
  defp expected_log(:full_history, :forwarded), do: [:replay_preflight]
  defp expected_log(_shape, _forwarding), do: [:native_turn_failed]

  # Every refusal line of this request, so a refusal logged twice (both
  # routes, or a line per retry) is seen.
  defp logged(log) do
    log
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        line =~ "stage=runtime_replay_preflight reason_code=model_not_allowed" and line =~ "public_code=model_not_allowed" -> [:replay_preflight]
        line =~ ~r/websocket native turn failed .*error_code=model_not_allowed/ -> [:native_turn_failed]
        true -> []
      end
    end)
  end

  defp put_serving_mode!(pool, exposed_model_ids, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for exposed_model_id <- exposed_model_ids do
      Repo.insert!(%ModelServingOverride{pool_id: pool.id, exposed_model_id: exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    end

    :ok
  end

  defp denial_of(%{"type" => "error", "status" => status, "error" => error}), do: {status, error["code"], error["type"], error["param"]}
  defp denial_of(other), do: {:not_refused, other["type"]}

  defp connect!(port, setup, thread_id) do
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
    {conn, websocket, ref}
  end

  defp receive_terminal_on!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> receive_terminal_on!(conn, websocket, ref)
    end
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "output" => [%{"type" => "message", "id" => "msg_c542", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}],
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        }
      })
    ])
  end

  defp turn_frame(model, thread_id) do
    thread_id
    |> base_frame(model, "#{thread_id}-turn-1", [prompt("first")])
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(thread_id, "#{thread_id}-turn-1", model, %{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  # As the released client sends a pre-turn compaction: the next turn's id,
  # the previous turn's response as the anchor and only the trigger.
  defp anchored_compaction_frame(thread_id, anchor) do
    turn_id = "#{thread_id}-turn-2"

    thread_id
    |> base_frame(@switched_model, turn_id, [%{"type" => "compaction_trigger"}])
    |> Map.put("previous_response_id", anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(thread_id, turn_id, @switched_model, %{"request_kind" => "compaction", "compaction" => compaction("pre_turn")}))
    |> CodexPooler.JSON.encode!()
  end

  # The whole history and the trigger, no anchor.
  defp full_history_compaction_frame(thread_id) do
    turn_id = "#{thread_id}-turn-2"

    input = [
      prompt("first"),
      %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]},
      prompt("second"),
      %{"type" => "compaction_trigger"}
    ]

    thread_id
    |> base_frame(@switched_model, turn_id, input)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(thread_id, turn_id, @switched_model, %{"request_kind" => "compaction", "compaction" => compaction("mid_turn")}))
    |> CodexPooler.JSON.encode!()
  end

  defp compaction(phase), do: %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => phase, "strategy" => "memento"}

  defp base_frame(thread_id, model, turn_id, input) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic instructions",
      "input" => input,
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
  end

  defp turn_metadata(thread_id, turn_id, model, extra) do
    %{
      "agent_name" => "/root",
      "context_window_id" => @context_window_id,
      "installation_id" => @installation_id,
      "root_turn_id" => turn_id,
      "session_id" => thread_id,
      "thread_id" => thread_id,
      "turn_id" => turn_id,
      "window_id" => "#{thread_id}:0",
      "window_number" => 0,
      "model" => model,
      "reasoning_effort" => "low"
    }
    |> Map.merge(extra)
    |> CodexPooler.JSON.encode!()
  end

  defp prompt(label), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{label} prompt"}]}

  # The refusal frame goes out before the row is written; poll the rows within
  # a detection budget.
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

  defp with_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      with_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
