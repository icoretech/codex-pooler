defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ReplayPreflightDenialRowParityTest do
  # With owner forwarding on, the owner's replay preflight refuses a
  # released-client turn whose model the key or the Pool refuses, before the
  # fresh pre-dispatch path sees it. Since findings#206 row 206-535 that
  # refusal is recorded after the preflight's rollback
  # (`replay_preflight_policy_denial_record_test.exs` pins the row, its status
  # and the log line). The row must be the one the fresh path writes for the
  # same refusal, so an operator reading the request log cannot tell which
  # route refused it: the websocket with forwarding off, and HTTP, record the
  # model the client asked for and the model the key's policy resolved it to
  # (`request_metadata` `requested_model`, `effective_model` and, for a key
  # that enforces a model, `enforced_model`). The preflight's row had none of
  # the three, so a refusal of an enforced model the Pool does not serve read
  # as a refusal of the requested model.
  #
  # A model the key does not allow that the Pool's catalog lists as active
  # but no assignment serves is `400 invalid_model` over HTTP and on the
  # fresh path, which judge the Pool's visible models before the key's
  # policy; the preflight judged the catalog row alone and answered
  # `model_not_allowed`, so the code depended on the forwarding mode
  # (findings#206 row 206-549).
  #
  # One node, native websocket with owner forwarding on and off, HTTP SSE,
  # the Pool's default serving mode and a Lite override, FakeUpstream, the
  # released client's turn frame, synthetic text.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @installation_id "00000000-0000-4000-8000-00000000c129"
  @context_window_id "00000000-0000-4000-8000-00000000c12a"
  @turn_endpoint "/backend-api/codex/responses"
  @enforced_model "gpt-enforced-fixture-model"
  @unserved_model "gpt-unserved-fixture-model"

  # The row fields a refusal writes that do not depend on the transport, the
  # connection or the generated ids.
  @metadata_keys ~w(endpoint requested_model effective_model enforced_model gateway_denial policy_denial)

  for arm <- [:model_not_allowed, :unknown_model, :retired_model, :enforced_model_not_served, :disallowed_unserved],
      mode <- [:default, "lite"],
      arm in [:model_not_allowed, :disallowed_unserved] or mode == :default do
    @tag arm: arm, serving_mode: mode
    test "websocket forwarded #{mode}: a turn refused #{arm} in the replay preflight records the row forwarding off and HTTP record", %{arm: arm, serving_mode: mode, conn: conn} do
      forwarded = websocket_row(arm, :forwarded, mode)
      direct = websocket_row(arm, :direct, mode)
      http = http_row(arm, mode, conn)

      CodexPooler.TestDiagnostics.puts(fn -> "P129 #{arm} #{mode}: #{inspect(%{forwarded: forwarded, direct: direct, http: http})}" end)

      assert forwarded.metadata["requested_model"] == requested_model(arm)
      assert http.last_error_code == http_code(arm)
      assert forwarded == direct
      assert forwarded == http
    end
  end

  # A key that enforces a model the Pool does not serve: the client asks for
  # the Pool's model, the key's policy substitutes the enforced one, and the
  # catalog refuses it (findings#206 row 206-604). HTTP answers `400
  # invalid_model` and records the requested, effective and enforced model;
  # the websocket answers and records the same on both forwarding modes, in
  # both serving modes, with one refusal line: the replay preflight's with
  # forwarding on, the failed turn's with it off.
  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "websocket #{mode}: a key enforcing a model the Pool does not serve is refused and recorded as HTTP refuses and records it", %{serving_mode: mode, conn: conn} do
      {forwarded, forwarded_lines} = logged_websocket_row(:enforced_model_not_served, :forwarded, mode)
      {direct, direct_lines} = logged_websocket_row(:enforced_model_not_served, :direct, mode)
      http = http_row(:enforced_model_not_served, mode, conn)

      CodexPooler.TestDiagnostics.puts(fn -> "206-604 enforced unserved #{mode}: #{inspect(%{forwarded: forwarded, direct: direct, http: http, lines: {forwarded_lines, direct_lines}})}" end)

      assert http.refused == {400, "invalid_model"}
      assert %{status: "rejected", response_status_code: 400, last_error_code: "invalid_model", pool_model?: false, upstream_requests: 0} = http

      assert Map.take(http.metadata, ["requested_model", "effective_model", "enforced_model"]) == %{
               "requested_model" => requested_model(:enforced_model_not_served),
               "effective_model" => @enforced_model,
               "enforced_model" => @enforced_model
             }

      assert forwarded == http
      assert direct == http
      assert forwarded_lines == [:replay_preflight]
      assert direct_lines == [:native_turn_failed]
    end
  end

  # Forwarding off, the socket keeps the policy its upgrade read and serves
  # the turn (a malformed policy is stored only once the socket is open), so
  # this refusal compares with HTTP alone.
  test "websocket forwarded: a malformed stored policy refused in the replay preflight records the row HTTP records", %{conn: conn} do
    forwarded = websocket_row(:policy_malformed, :forwarded, :default)
    http = http_row(:policy_malformed, :default, conn)

    CodexPooler.TestDiagnostics.puts(fn -> "P129 policy_malformed: #{inspect(%{forwarded: forwarded, http: http})}" end)

    assert forwarded.metadata["requested_model"] == requested_model(:policy_malformed)
    assert forwarded == http
  end

  defp websocket_row(arm, forwarding, mode), do: arm |> logged_websocket_row(forwarding, mode) |> elem(0)

  # The row projection with what the client received, and which refusal line
  # the socket logged.
  defp logged_websocket_row(arm, forwarding, mode) do
    put_owner_forwarding!(forwarding)
    thread_id = Ecto.UUID.generate()
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream, compact?: true)
    put_serving_mode!(setup, mode)
    {_server, port} = start_public_endpoint_with_server!()
    {model, after_upgrade} = impose!(arm, setup)
    {terminal, log} = with_info_log(fn -> send_once!(port, setup, thread_id, model, after_upgrade) end)
    assert %{"type" => "error", "status" => status, "error" => %{"code" => code}} = terminal
    {Map.put(project(await_settled!(setup.pool.id, 1), setup, upstream), :refused, {status, code}), refusal_lines(log, code)}
  end

  defp refusal_lines(log, code) do
    log
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        line =~ "stage=runtime_replay_preflight reason_code=#{code}" and line =~ "public_code=#{code}" -> [:replay_preflight]
        line =~ ~r/websocket native turn failed .*error_code=#{code}/ -> [:native_turn_failed]
        true -> []
      end
    end)
  end

  defp with_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.with_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp http_row(arm, mode, conn) do
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream, compact?: true)
    put_serving_mode!(setup, mode)
    {model, after_upgrade} = impose!(arm, setup)
    after_upgrade.()

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("content-type", "application/json")
      |> post(@turn_endpoint, CodexPooler.JSON.encode!(%{"model" => model, "instructions" => "synthetic instructions", "input" => [prompt()], "tools" => [], "store" => false, "stream" => true}))

    assert conn.status in 400..499
    code = conn.resp_body |> CodexPooler.JSON.decode!() |> get_in(["error", "code"])
    Map.put(project(await_settled!(setup.pool.id, 1), setup, upstream), :refused, {conn.status, code})
  end

  defp project(rows, setup, upstream) do
    [row] = rows

    %{
      status: row.status,
      response_status_code: row.response_status_code,
      last_error_code: row.last_error_code,
      usage_status: row.usage_status,
      endpoint: row.endpoint,
      requested_model: row.requested_model,
      pool_model?: row.model_id == setup.model.id,
      metadata: Map.take(row.request_metadata, @metadata_keys),
      upstream_requests: FakeUpstream.count(upstream)
    }
  end

  defp http_code(:model_not_allowed), do: "model_not_allowed"
  defp http_code(_arm), do: "invalid_model"

  defp requested_model(:unknown_model), do: "gpt-unknown-fixture-model"
  defp requested_model(:disallowed_unserved), do: @unserved_model
  defp requested_model(_arm), do: "gpt-test-model"

  defp impose!(:model_not_allowed, setup) do
    setup.api_key |> Ecto.Changeset.change(allowed_model_identifiers: ["another-model-fixture"]) |> Repo.update!()
    {setup.model.exposed_model_id, fn -> :ok end}
  end

  defp impose!(:unknown_model, _setup), do: {requested_model(:unknown_model), fn -> :ok end}

  defp impose!(:retired_model, setup) do
    setup.model |> Ecto.Changeset.change(status: "retired") |> Repo.update!()
    {setup.model.exposed_model_id, fn -> :ok end}
  end

  # The key enforces a model the Pool does not serve: the client asks for the
  # Pool's model and the key's policy substitutes one the catalog refuses.
  defp impose!(:enforced_model_not_served, setup) do
    setup.api_key |> Ecto.Changeset.change(allowed_model_identifiers: [@enforced_model], enforced_model_identifier: @enforced_model) |> Repo.update!()
    {setup.model.exposed_model_id, fn -> :ok end}
  end

  # The Pool's catalog lists a second active model that no assignment serves
  # (no source assignment), and the key allows only the Pool's served model.
  defp impose!(:disallowed_unserved, setup) do
    CodexPooler.PoolerFixtures.model_fixture(setup.pool, %{exposed_model_id: @unserved_model, display_name: "Unserved fixture model", source_assignment_count: 0})
    setup.api_key |> Ecto.Changeset.change(allowed_model_identifiers: [setup.model.exposed_model_id]) |> Repo.update!()
    {@unserved_model, fn -> :ok end}
  end

  # A stored policy the changesets would reject fails closed at
  # normalization; the upgrade refuses it, so it is stored after the upgrade.
  defp impose!(:policy_malformed, setup) do
    {setup.model.exposed_model_id, fn -> {1, _} = Repo.update_all(from(key in CodexPooler.Access.APIKey, where: key.id == ^setup.api_key.id), set: [allowed_model_identifiers: ["gpt 5"]]) end}
  end

  defp put_serving_mode!(_setup, :default), do: :ok

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for exposed_model_id <- [setup.model.exposed_model_id, @unserved_model] do
      Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    end

    :ok
  end

  # One request on its own connection, as the released client sends a turn.
  defp send_once!(port, setup, thread_id, model, after_upgrade) do
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
    after_upgrade.()

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(model, thread_id))
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

  # The released client's turn frame: its turn metadata makes it
  # replay-eligible, so with forwarding on the owner's replay preflight judges
  # it first.
  defp frame(model, thread_id) do
    turn_id = "#{thread_id}-turn"
    window_id = "#{thread_id}:0"

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model,
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
            "model" => model,
            "reasoning_effort" => "low"
          })
      }
    })
  end

  defp prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic policy denial prompt"}]}

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

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
