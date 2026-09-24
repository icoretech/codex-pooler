defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ReplayPreflightPolicyDenialRecordTest do
  # The released client's turn frame carries `x-codex-turn-metadata`
  # (request_kind `turn`), which makes it replay-eligible: with owner
  # forwarding on, the owner's replay preflight judges it before the fresh
  # pre-dispatch path does. That preflight refuses a model the key may not use
  # (`model_not_allowed`) and a model the Pool does not serve
  # (`invalid_model`) inside its transaction and rolled back with the refusal
  # and nothing else: the client got the right frame, but no request row and
  # no log line were written, while forwarding off and HTTP recorded `rejected
  # 400` (production rev 50, Codex 0.156.1, S18 2026-09-24). A stored policy
  # that fails normalization was also answered `model_not_allowed` there
  # instead of its own `403 api_key_policy_malformed`. Each refusal is now
  # recorded after the rollback, as forwarding off records it, and logged on
  # the preflight's refusal line.
  #
  # One node, native websocket with owner forwarding on and off, the Pool's
  # serving mode forced to Full (every arm) and to Lite (`model_not_allowed`),
  # FakeUpstream, the released client's frame and key sets, synthetic text.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @installation_id "00000000-0000-4000-8000-00000000c112"
  @context_window_id "00000000-0000-4000-8000-00000000c113"
  @turn_endpoint "/backend-api/codex/responses"

  # arm => {status, code, type, param, recorded against the Pool's model?}
  @refusals %{
    model_not_allowed: {400, "model_not_allowed", "invalid_request_error", "model", true},
    unknown_model: {400, "invalid_model", "invalid_request_error", "model", false},
    retired_model: {400, "invalid_model", "invalid_request_error", "model", false},
    policy_malformed: {403, "api_key_policy_malformed", "invalid_request_error", nil, false},
    reasoning_effort_not_allowed: {400, "reasoning_effort_not_allowed", "invalid_request_error", "reasoning.effort", true}
  }

  # A malformed policy reaches a turn only once the socket is open (the
  # upgrade refuses it); forwarding off, the socket keeps the policy its
  # upgrade read and runs the turn, so that arm is forwarding on only.
  for arm <- [:model_not_allowed, :unknown_model, :retired_model, :policy_malformed, :reasoning_effort_not_allowed],
      forwarding <- [:forwarded, :direct],
      mode <- ["full", "lite"],
      arm == :model_not_allowed or mode == "full",
      arm != :policy_malformed or forwarding == :forwarded do
    @tag arm: arm, forwarding: forwarding, serving_mode: mode
    test "websocket #{forwarding} #{mode}: a released-client turn refused #{arm} is answered, recorded and logged as forwarding off does", %{arm: arm, forwarding: forwarding, serving_mode: mode} do
      {status, code, type, param, model?} = @refusals[arm]
      measured = run_refusal(arm, forwarding, mode)

      assert measured == %{
               refused: {status, code, type, param},
               rows: [{"rejected", code, status, "websocket", model?}],
               upstream_requests: 0,
               logged: expected_log(arm, forwarding)
             }
    end
  end

  # A native frame sent the moment the previous turn completes is queued, and
  # its dequeue asks the replay preflight only whether it may attach the replay
  # binding: after any refusal there it submits the frame to the ordinary
  # checks, which record their own verdict. Here the key's allowed models are
  # narrowed between the two turns (a policy edit does not advance the key's
  # runtime epoch): the preflight reads the key again and refuses, while the
  # ordinary checks use the policy the upgrade read and serve the turn. Each
  # frame leaves exactly one row, a refusal only when the client was refused;
  # recording the preflight's refusal there too left a `rejected` row beside
  # the served one.
  test "websocket forwarded: a queued turn the preflight refuses leaves one row, the verdict of the checks that answered it" do
    put_owner_forwarding!(:forwarded)
    thread_id = Ecto.UUID.generate()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", respond: completed_frames("resp_p112_queued_a")),
          FakeUpstream.expect_request(method: "WEBSOCKET", respond: completed_frames("resp_p112_queued_b"))
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = connect!(port, setup, thread_id)
    frame_a = frame(setup.model.exposed_model_id, "low", thread_id)
    frame_b = frame_a |> CodexPooler.JSON.decode!() |> put_in(["client_metadata", "turn_id"], "#{thread_id}-next") |> Map.update!("input", &(&1 ++ [prompt()])) |> CodexPooler.JSON.encode!()

    {served_a, served_b} =
      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame_a)
        {conn, websocket, served_a} = receive_terminal_on!(conn, websocket, ref)
        setup.api_key |> Ecto.Changeset.change(allowed_model_identifiers: ["another-model-fixture"]) |> Repo.update!()
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame_b)
        {_conn, _websocket, served_b} = receive_terminal_on!(conn, websocket, ref)
        {served_a, served_b}
      after
        Mint.HTTP.close(conn)
      end

    rows = setup.pool.id |> await_settled!(2) |> Enum.map(&{&1.status, &1.last_error_code})
    refused_b? = served_b["type"] == "error"

    CodexPooler.TestDiagnostics.puts(fn -> "P112 queued forwarded: #{inspect(%{a: served_a["type"], b: {served_b["type"], get_in(served_b, ["error", "code"])}, rows: rows})}" end)

    assert served_a["type"] == "response.completed"
    assert length(rows) == 2
    assert Enum.count(rows, &match?({"rejected", _code}, &1)) == if(refused_b?, do: 1, else: 0)
  end

  defp run_refusal(arm, forwarding, mode) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream, compact?: true)
    put_serving_mode!(setup, mode)
    {_server, port} = start_public_endpoint_with_server!()
    {requested_model, after_upgrade} = impose!(arm, setup)
    effort = if arm == :reasoning_effort_not_allowed, do: "high", else: "low"

    {{terminal, rows}, log} =
      with_info_log(fn ->
        terminal = send_once!(port, setup, thread_id, {requested_model, effort}, after_upgrade)
        {terminal, await_settled!(setup.pool.id, 1)}
      end)

    {_status, code, _type, _param, _model?} = @refusals[arm]

    measured = %{
      refused: denial_of(terminal),
      rows: Enum.map(rows, &{&1.status, &1.last_error_code, &1.response_status_code, &1.transport, &1.model_id == setup.model.id}),
      upstream_requests: FakeUpstream.count(upstream),
      logged: logged(log, code)
    }

    CodexPooler.TestDiagnostics.puts(fn -> "P112 websocket #{arm} #{forwarding} #{mode}: #{inspect(measured)}" end)
    measured
  end

  # Forwarding off, the socket runs the turn and logs its failure; forwarding
  # on, the owner's replay preflight refuses a model refusal and logs its
  # refusal line. A reasoning refusal comes after the preflight admitted the
  # frame, so the turn fails as forwarding off (a pin: it was recorded before).
  defp expected_log(:reasoning_effort_not_allowed, _forwarding), do: :native_turn_failed
  defp expected_log(_arm, :direct), do: :native_turn_failed
  defp expected_log(_arm, :forwarded), do: :replay_preflight

  defp logged(log, code) do
    cond do
      log =~ "stage=runtime_replay_preflight reason_code=#{code}" and log =~ "public_code=#{code}" -> :replay_preflight
      log =~ ~r/websocket native turn failed .*error_code=#{code}/ -> :native_turn_failed
      true -> :none
    end
  end

  defp impose!(:model_not_allowed, setup) do
    setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: ["another-model-fixture"])
    |> Repo.update!()

    {setup.model.exposed_model_id, fn -> :ok end}
  end

  defp impose!(:unknown_model, _setup), do: {"gpt-unknown-fixture-model", fn -> :ok end}

  defp impose!(:retired_model, setup) do
    setup.model |> Ecto.Changeset.change(status: "retired") |> Repo.update!()
    {setup.model.exposed_model_id, fn -> :ok end}
  end

  # A stored policy the changesets would reject (a model identifier with a
  # space) fails closed at normalization. The upgrade already refuses it with
  # `403`, so it is stored once the socket is open.
  defp impose!(:policy_malformed, setup) do
    {setup.model.exposed_model_id, fn -> {1, _} = Repo.update_all(from(key in CodexPooler.Access.APIKey, where: key.id == ^setup.api_key.id), set: [allowed_model_identifiers: ["gpt 5"]]) end}
  end

  # Refused at pre-dispatch, after the replay preflight admitted the frame.
  defp impose!(:reasoning_effort_not_allowed, setup) do
    setup.api_key |> Ecto.Changeset.change(maximum_reasoning_effort: "medium") |> Repo.update!()
    {setup.model.exposed_model_id, fn -> :ok end}
  end

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: setup.model.exposed_model_id,
      mode: mode,
      created_at: timestamp,
      updated_at: timestamp
    })

    :ok
  end

  defp denial_of(%{"type" => "error", "status" => status, "error" => error}), do: {status, error["code"], error["type"], error["param"]}

  defp denial_of(other), do: {:not_refused, other["type"]}

  defp connect!(port, setup, thread_id) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, upgrade_headers(setup, thread_id))
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref}
  end

  defp upgrade_headers(setup, thread_id) do
    [
      {"authorization", setup.authorization},
      {"session-id", thread_id},
      {"thread-id", thread_id},
      {"x-client-request-id", thread_id},
      {"x-codex-window-id", "#{thread_id}:0"}
    ]
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
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ])
  end

  # One request on its own connection, as the released client sends a turn.
  defp send_once!(port, setup, thread_id, {requested_model, effort}, after_upgrade) do
    {conn, websocket, ref} = connect!(port, setup, thread_id)
    after_upgrade.()

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(requested_model, effort, thread_id))
      {_conn, _websocket, terminal} = receive_terminal_on!(conn, websocket, ref)
      terminal
    after
      Mint.HTTP.close(conn)
    end
  end

  # The released client's first turn frame: its turn metadata makes the frame
  # replay-eligible, so the owner's replay preflight judges it first.
  defp frame(requested_model, effort, thread_id) do
    turn_id = "#{thread_id}-turn"
    window_id = "#{thread_id}:0"

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => requested_model,
      "instructions" => "synthetic instructions",
      "input" => [prompt()],
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => effort},
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
        "x-codex-window-id" => window_id,
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "agent_name" => "/root",
            "context_window_id" => @context_window_id,
            "installation_id" => @installation_id,
            "request_kind" => "turn",
            "root_turn_id" => turn_id,
            "session_id" => thread_id,
            "thread_id" => thread_id,
            "turn_id" => turn_id,
            "window_id" => window_id,
            "window_number" => 0,
            "model" => requested_model,
            "reasoning_effort" => effort
          })
      }
    })
  end

  defp prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic policy denial prompt"}]}

  # The socket writes the terminal before any row settles; poll the rows
  # within a detection budget.
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
