defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketSubagentCompactionTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Websocket.{NativeCompactionAdmission, WebsocketOwnerSession}
  alias CodexPooler.Repo

  # A released Codex client (`rust-v0.156.1`) running a spawned agent opens
  # the child's websocket with the root's `session-id`
  # (`ModelClient::responses_session_id`, non-root agents), but with the
  # child's own `thread-id`, `x-client-request-id` and `x-codex-window-id`
  # (`<child thread>:<window number>`), plus `x-codex-parent-thread-id` and
  # `x-openai-subagent: collab_spawn`. It never sends `x-codex-turn-state` on
  # an upgrade. The Pooler keys the session on the window before `session-id`,
  # so parent and child get separate sessions and owners, and a child's attach
  # cannot clear the parent's armed native compaction admission (nor the
  # reverse), the clear `c367a8b5a` added for a socket replaced at one owner
  # (findings#206 rows 206-285 and 206-265). A live released-client
  # multi-agent run keyed its parent and four child sockets on five distinct
  # window sessions. Were both sockets keyed on one owner, the child's attach
  # would replace the parent there, and the parent's compaction would be
  # refused `duplicate_downstream` at the owner before any upstream send, with
  # or without that clear. Identifiers and prompt text are synthetic.
  @root_session_id "019a0000-0000-7000-8000-00000000c001"
  @parent_thread_id "019a0000-0000-7000-8000-00000000c002"
  @child_thread_id "019a0000-0000-7000-8000-00000000c003"
  @parent_anchor "resp_subagent_parent_anchor_01"
  @child_anchor "resp_subagent_child_anchor_001"
  @parent_compact "resp_subagent_parent_compact1"
  @child_compact "resp_subagent_child_compact01"
  @installation_id "00000000-0000-4000-8000-00000000c004"

  test "owner_forwarded parent and subagent sockets on one root session keep their own compaction admissions" do
    put_owner_forwarding!()
    parent_item = %{"type" => "compaction", "encrypted_content" => "synthetic-subagent-parent"}
    child_item = %{"type" => "compaction", "encrypted_content" => "synthetic-subagent-child"}

    upstream =
      start_upstream(
        # Strict finite scenario: each agent's ordinary turn and its post-turn
        # compact run on that agent's own upstream connection, interleaved so
        # every compact follows the other agent's attach and turn.
        # provenance: released-client header and frame shapes; reply frames synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@parent_anchor)),
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 2, json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@child_anchor)),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => @parent_anchor, "input.0.type" => "compaction_trigger"}],
            respond: compaction_frames(parent_item, @parent_compact)
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => @child_anchor, "input.0.type" => "compaction_trigger"}],
            respond: compaction_frames(child_item, @child_compact)
          )
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()

    parent = connect!(port, setup, :parent)

    try do
      parent = ordinary_turn!(parent, setup, @parent_anchor)
      parent_owner = owner_for_turn!(setup, 0)
      parent_admission = await_pending_compact!(parent_owner)

      child = connect!(port, setup, :child)

      try do
        child = ordinary_turn!(child, setup, @child_anchor)
        child_owner = owner_for_turn!(setup, 1)
        child_admission = await_pending_compact!(child_owner)

        assert :sys.get_state(parent_owner).native_compaction_admission == parent_admission

        parent = post_turn_compaction!(parent, setup, @parent_anchor, parent_item)
        assert :sys.get_state(child_owner).native_compaction_admission == child_admission

        _child = post_turn_compaction!(child, setup, @child_anchor, child_item)
        _parent = parent

        compact_rows = await_compact_rows!(setup, 2)
        assert Enum.map(compact_rows, &{&1.transport, &1.status}) == [{"websocket", "succeeded"}, {"websocket", "succeeded"}]

        for row <- compact_rows do
          assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^row.id and entry.entry_kind == "settlement"), :count) == 1
        end

        assert [parent_turn, child_turn, parent_compact, child_compact] = FakeUpstream.requests(upstream)
        assert parent_compact.websocket_connection_id == parent_turn.websocket_connection_id
        assert child_compact.websocket_connection_id == child_turn.websocket_connection_id
        assert parent_turn.websocket_connection_id != child_turn.websocket_connection_id
        assert :ok = FakeUpstream.verify!(upstream)

        assert child_owner != parent_owner
        assert window_session_ids(setup) == MapSet.new([session_id_for_turn!(setup, 0), session_id_for_turn!(setup, 1)])
      after
        Mint.HTTP.close(child.conn)
      end
    after
      Mint.HTTP.close(parent.conn)
    end
  end

  defp connect!(port, setup, agent) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    thread = thread(agent)

    headers =
      [
        {"authorization", setup.authorization},
        {"session-id", @root_session_id},
        {"thread-id", thread},
        {"x-client-request-id", thread},
        {"x-codex-window-id", window(agent)}
      ] ++ subagent_headers(agent)

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/backend-api/codex/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    %{conn: conn, websocket: websocket, ref: ref, agent: agent}
  end

  defp subagent_headers(:parent), do: []
  defp subagent_headers(:child), do: [{"x-codex-parent-thread-id", @parent_thread_id}, {"x-openai-subagent", "collab_spawn"}]

  defp ordinary_turn!(client, setup, response_id) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, turn_frame(setup, client.agent))
    {conn, websocket, created} = public_websocket_receive_text!(conn, websocket, client.ref)
    {conn, websocket, completed} = public_websocket_receive_text!(conn, websocket, client.ref)
    assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)
    assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} = CodexPooler.JSON.decode!(completed)
    %{client | conn: conn, websocket: websocket}
  end

  defp post_turn_compaction!(client, setup, anchor, item) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, post_turn_frame(setup, client.agent, anchor))
    {conn, websocket, done} = public_websocket_receive_text!(conn, websocket, client.ref)
    assert CodexPooler.JSON.decode!(done) == %{"type" => "response.output_item.done", "item" => item}
    {conn, websocket, terminal} = public_websocket_receive_text!(conn, websocket, client.ref)
    assert %{"type" => "response.completed", "response" => %{"status" => "completed", "output" => [^item]}} = CodexPooler.JSON.decode!(terminal)
    %{client | conn: conn, websocket: websocket}
  end

  # The session and owner an agent's socket attached to, read from the
  # session of the agent's ordinary turn (the `index`-th turn of the Pool).
  defp owner_for_turn!(setup, index) do
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(session_id_for_turn!(setup, index))
    owner_pid
  end

  defp session_id_for_turn!(setup, index) do
    turns =
      Repo.all(
        from(turn in CodexTurn,
          join: request in Request,
          on: request.id == turn.request_id,
          where: request.pool_id == ^setup.pool.id and request.endpoint == "/backend-api/codex/responses",
          order_by: request.admitted_at,
          select: turn.codex_session_id
        )
      )

    Enum.at(turns, index) || flunk("no ordinary turn #{index} recorded")
  end

  # Each agent's window keys its own session (`SessionContinuity` hashes the
  # window into the key).
  defp window_session_ids(setup) do
    keys = Enum.map([:parent, :child], &("x-codex-window-id:" <> Base.encode16(:crypto.hash(:sha256, window(&1)), case: :lower)))

    Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id and session.session_key in ^keys, select: session.id))
    |> MapSet.new()
  end

  # The ordinary success arms the admission after the terminal frame left the
  # owner; poll the owner's authoritative state (no completion signal reaches
  # the test process).
  defp await_pending_compact!(owner_pid) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Stream.repeatedly(fn -> :sys.get_state(owner_pid).native_compaction_admission end)
    |> Enum.reduce_while(nil, fn
      %NativeCompactionAdmission{phase: :pending_compact} = admission, _acc ->
        {:halt, admission}

      _other, _acc ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("owner never armed the native compaction admission")
        Process.sleep(10)
        {:cont, nil}
    end)
  end

  defp await_compact_rows!(setup, count) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Stream.repeatedly(fn ->
      Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id and request.endpoint == "/backend-api/codex/responses/compact", order_by: request.admitted_at))
    end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      settled? = length(rows) >= count and Enum.all?(rows, &(&1.status != "in_progress"))

      cond do
        settled? -> {:halt, rows}
        System.monotonic_time(:millisecond) > deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp put_owner_forwarding! do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous do
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp thread(:parent), do: @parent_thread_id
  defp thread(:child), do: @child_thread_id

  defp window(agent), do: "#{thread(agent)}:0"

  defp context_window_id(:parent), do: "00000000-0000-4000-8000-00000000c021"
  defp context_window_id(:child), do: "00000000-0000-4000-8000-00000000c022"

  defp turn_id(:parent), do: "019a0000-0000-7000-8000-00000000c011"
  defp turn_id(:child), do: "019a0000-0000-7000-8000-00000000c012"

  defp turn_frame(setup, agent) do
    setup
    |> frame(agent, [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{agent} prompt"}]}])
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(agent, %{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  defp post_turn_frame(setup, agent, anchor) do
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "post_turn", "strategy" => "memento"}

    setup
    |> frame(agent, [%{"type" => "compaction_trigger"}])
    |> Map.put("previous_response_id", anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(agent, %{"request_kind" => "compaction", "compaction" => compaction}))
    |> CodexPooler.JSON.encode!()
  end

  defp frame(setup, agent, input) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => input,
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "text" => %{"verbosity" => "low"},
      "prompt_cache_key" => thread(agent),
      "client_metadata" => %{
        "session_id" => @root_session_id,
        "thread_id" => thread(agent),
        "turn_id" => turn_id(agent),
        "root_turn_id" => turn_id(agent),
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => window(agent),
        "x-codex-ws-stream-request-start-ms" => "1790000000000"
      }
    }
  end

  defp turn_metadata(agent, extra) do
    %{
      "agent_name" => if(agent == :parent, do: "/root", else: "/root/child"),
      "analytics_enabled" => true,
      "auto_review_enabled" => false,
      "context_window_id" => context_window_id(agent),
      "installation_id" => @installation_id,
      "sandbox" => "seccomp",
      "sandbox_mode" => "read-only",
      "thread_source" => if(agent == :parent, do: "user", else: "subagent"),
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "turn_trigger" => "exec",
      "session_id" => @root_session_id,
      "thread_id" => thread(agent),
      "turn_id" => turn_id(agent),
      "root_turn_id" => turn_id(agent),
      "window_id" => window(agent),
      "window_number" => 0,
      "model" => "gpt-test-model",
      "reasoning_effort" => "low"
    }
    |> Map.merge(extra)
    |> CodexPooler.JSON.encode!()
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 20_000, "output_tokens" => 1, "total_tokens" => 20_001}}
      })
    ])
  end

  defp compaction_frames(item, response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item]}})
    ])
  end
end
