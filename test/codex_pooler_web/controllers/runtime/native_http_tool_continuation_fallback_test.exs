defmodule CodexPoolerWeb.Runtime.NativeHttpToolContinuationFallbackTest do
  use CodexPoolerWeb.ConnCase, async: false
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [start_shared_bridge_peer!: 0, start_shared_peer_window_owner!: 3]
  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.{NativeHttpTurnIdentity, RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox
  @path "/backend-api/codex/responses"
  @budget 15_000
  @moduletag capture_log: true

  setup_all do
    %{peer: start_shared_bridge_peer!()}
  end

  for mode <- ["full", "lite"], topology <- [:local, :remote], lifecycle <- [:live, :provider_terminal] do
    test "#{mode} #{topology} #{lifecycle} tool fallback keeps identity across owner topology", context do
      run_live_fallback(unquote(mode), unquote(lifecycle), :none, unquote(topology), context.peer)
    end
  end

  for mode <- ["full", "lite"], lifecycle <- [:live, :provider_terminal, :stream_cut, :completed_cut] do
    test "#{mode} #{lifecycle} websocket tool continuation meets its HTTP fallback" do
      run_live_fallback(unquote(mode), unquote(lifecycle))
    end
  end

  for mode <- ["full", "lite"], fault <- [:expired, :epoch, :changed_output, :late_async, :concurrent, :epoch_after_wait, :multiple_roots, :other_key, :null_type, :null_marker, :epoch_typed, :epoch_typed_marked] do
    test "#{mode} tool fallback #{fault} preserves existing predecessor policy" do
      run_live_fallback(unquote(mode), :provider_terminal, unquote(fault))
    end
  end

  for mode <- ["full", "lite"], legacy_state <- [:accepted, :zero_output_terminal] do
    test "#{mode} single legacy HTTP #{legacy_state} root stays discoverable" do
      legacy_http_root(unquote(mode), unquote(legacy_state))
    end
  end

  defp legacy_http_root(mode, legacy_state) do
    upstream = start_upstream(FakeUpstream.sse_stream([{"response.completed", %{"type" => "response.completed", "response" => %{"status" => "completed", "output" => []}}}]))
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    thread = Ecto.UUID.generate()
    metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => Ecto.UUID.generate(), "request_kind" => "turn"}
    encoded = CodexPooler.JSON.encode!(metadata)
    body = %{"model" => setup.model.exposed_model_id, "instructions" => "synthetic", "stream" => true, "store" => false, "input" => native_text_input("synthetic opener") ++ [%{"type" => "function_call_output", "call_id" => "call_synthetic", "output" => "synthetic result"}], "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", encoded)}
    {:ok, session} = Websocket.start_codex_session(auth, %{accepted_turn_state: thread})
    opts = RequestOptions.build(%{transport: "http_sse", codex_session: session, api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch}, @path, body)
    {:ok, claim} = NativeHttpTurnIdentity.request_claim(opts, body)
    {:ok, legacy_digest} = WebsocketTurnIdentity.replay_claim_digest(claim.semantic_turn_key, body)
    {:ok, legacy_witness} = ClientRetry.original_witness(legacy_digest, auth.api_key.runtime_revocation_epoch)
    legacy_key = WebsocketTurnIdentity.request_claim_key(claim.semantic_turn_key, body)
    {:ok, legacy} = Accounting.reserve(auth, setup.model, body, %{endpoint: @path, transport: "http_sse", codex_session: session, correlation_id: legacy_key, native_client_retry_witness: legacy_witness, runtime_revocation_epoch: auth.api_key.runtime_revocation_epoch, request_metadata: %{"native_http_claim_arm" => "tool_continuation"}})
    if legacy_state == :zero_output_terminal, do: assert({:ok, _} = Accounting.finalize_reserved_request_failure(legacy.request, %{last_error_code: "no_eligible_backend"}))
    {listener, port} = start_public_endpoint_with_server!()
    monitor = Process.monitor(listener)
    headers = [{"authorization", setup.authorization}, {"x-codex-turn-state", thread}, {"session-id", thread}, {"thread-id", thread}, {"x-codex-turn-metadata", encoded}]
    headers = if mode == "lite", do: [{"x-openai-internal-codex-responses-lite", "true"} | headers], else: headers
    response = Req.post!("http://127.0.0.1:#{port}#{@path}", json: body, headers: headers, retry: false, receive_timeout: @budget)
    assert legacy.request.native_client_retry_digest == legacy_digest

    if legacy_state == :accepted do
      assert response.status == 409
      assert response.body["error"]["code"] == "duplicate_turn"
      refute Repo.exists?(from r in Request, where: r.pool_id == ^setup.pool.id and r.id != ^legacy.request.id)
      assert FakeUpstream.http_request_count(upstream) == 0
      assert {:ok, _} = Accounting.finalize_reserved_request_failure(legacy.request, %{last_error_code: "owner_drained"})
    else
      assert response.status == 200
      assert [successor] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id and r.id != ^legacy.request.id)
      {:ok, expected} = ClientRetry.deterministic_failed_predecessor_claim(legacy_key, legacy.request.id)
      assert successor.correlation_id == expected
      assert FakeUpstream.http_request_count(upstream) == 1
    end

    if directory = System.get_env("TOOL_IDENTITY_EVIDENCE"), do: File.write!(Path.join(directory, "#{mode}-legacy-#{legacy_state}.json"), CodexPooler.JSON.encode!(%{legacy_primary_preserved: true, legacy_stored_witness_preserved: true, successor_uses_existing_chain: legacy_state == :zero_output_terminal, http_status: response.status, new_provider_calls: FakeUpstream.http_request_count(upstream), root_count: 1}))
    :ok = ThousandIsland.stop(listener)
    assert_receive {:DOWN, ^monitor, :process, ^listener, _}, @budget
  end

  defp run_live_fallback(mode, lifecycle, fault \\ :none, topology \\ :off, peer \\ nil) do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, topology != :off)
    release = make_ref()
    held = provider_reply(lifecycle, release)
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "WEBSOCKET", path: @path, respond: held), FakeUpstream.expect_request(method: "POST", path: @path, respond: FakeUpstream.sse_stream([{"response.completed", %{"type" => "response.completed", "response" => %{"status" => "completed", "output" => []}}}]))]))
    setup = gateway_setup(upstream)
    if topology != :remote, do: register_unboxed_pool_cleanup!(setup)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    {listener, port} = start_public_endpoint_with_server!()
    listener_monitor = Process.monitor(listener)
    thread = Ecto.UUID.generate()
    window = "#{thread}:0"
    if topology == :remote, do: start_shared_peer_window_owner!(setup, window, peer)
    metadata = %{"window_id" => window, "window_number" => 0, "session_id" => thread, "thread_id" => thread, "turn_id" => Ecto.UUID.generate(), "request_kind" => "turn"}
    encoded = CodexPooler.JSON.encode!(metadata)
    input = native_text_input("synthetic opener") ++ [%{"type" => "function_call", "call_id" => "call_synthetic", "name" => "sample_tool", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => "call_synthetic", "output" => "synthetic tool result"}]
    body = %{"model" => setup.model.exposed_model_id, "instructions" => "synthetic", "input" => input, "stream" => true, "store" => false, "client_metadata" => Map.put(metadata, "x-codex-turn-metadata", encoded)}
    frame = Map.put(body, "type", "response.create")
    frame = if mode == "lite", do: put_in(frame, ["client_metadata", "ws_request_header_x_openai_internal_codex_responses_lite"], "true"), else: frame
    headers = [{"session-id", thread}, {"thread-id", thread}, {"x-codex-window-id", window}]
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, thread, @path, headers)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(frame))

      original = observe_original(%{conn: conn, websocket: websocket, ref: ref, setup: setup, upstream: upstream, release: release}, lifecycle, topology, peer)
      execute_fallback(%{mode: mode, topology: topology, lifecycle: lifecycle, fault: fault}, %{setup: setup, body: body, original: original, upstream: upstream, headers: headers, thread: thread, encoded: encoded, port: port})
    after
      FakeUpstream.release_remaining_frames(upstream, release)
      if lifecycle == :live, do: assert_receive({CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @budget)
      Mint.HTTP.close(conn)
      :ok = ThousandIsland.stop(listener)
      assert_receive {:DOWN, ^listener_monitor, :process, ^listener, _}, @budget
    end
  end

  defp observe_original(%{conn: conn, websocket: websocket, ref: ref, setup: setup, upstream: upstream, release: release}, lifecycle, topology, peer) do
    if lifecycle not in [:stream_cut, :completed_cut] do
      assert_receive {:fake_upstream_frame_barrier, 0, _, ^release}, @budget
      :ok = FakeUpstream.release_frame(upstream, release)
      assert_receive {:fake_upstream_frame_barrier, 1, _, ^release}, @budget
    end

    {conn, websocket, created} = public_websocket_receive_text!(conn, websocket, ref)
    assert CodexPooler.JSON.decode!(created)["type"] == "response.created"

    if lifecycle not in [:stream_cut, :completed_cut] do
      :ok = FakeUpstream.release_frame(upstream, release)
      assert_receive {:fake_upstream_frame_barrier, 2, _, ^release}, @budget
    end

    {_conn, _websocket, delta} = public_websocket_receive_text!(conn, websocket, ref)
    assert CodexPooler.JSON.decode!(delta)["type"] == if(lifecycle == :completed_cut, do: "response.output_item.done", else: "response.output_text.delta")
    assert [original] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    if lifecycle not in [:stream_cut, :completed_cut], do: assert(original.status == "in_progress")
    if topology == :remote, do: assert(original.request_metadata["websocket_owner_forwarding"]["owner_instance_id"] == Atom.to_string(peer))
    assert Repo.get_by!(CodexTurn, request_id: original.id).first_visible_output_at

    if lifecycle in [:provider_terminal, :stream_cut, :completed_cut] do
      if lifecycle == :provider_terminal, do: assert(:ok == FakeUpstream.release_remaining_frames(upstream, release))
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @budget
    end

    if lifecycle in [:stream_cut, :completed_cut] do
      stored = Repo.reload!(original)
      turn = Repo.get_by!(CodexTurn, request_id: original.id)
      assert ClientRetry.verified_identical_resend?(turn, stored, Repo.get!(Attempt, turn.final_attempt_id))
    end

    original
  end

  defp execute_fallback(%{mode: mode, topology: topology, lifecycle: lifecycle, fault: fault}, %{setup: setup, body: body, original: original, upstream: upstream, headers: headers, thread: thread, encoded: encoded, port: port}) do
    body = alter_fallback(fault, body, original, setup)
    legacy = if fault == :multiple_roots, do: create_legacy_conflicting_root(setup, body, original)
    http_headers = [{"authorization", setup.authorization}, {"x-codex-turn-state", thread}, {"x-codex-turn-metadata", encoded} | headers]
    http_headers = if mode == "lite", do: [{"x-openai-internal-codex-responses-lite", "true"} | http_headers], else: http_headers

    if fault in [:concurrent, :epoch_after_wait] do
      assert_concurrent_aliases(setup, body, original, mode, fault)
    else
      http_headers = if fault == :other_key, do: List.keyreplace(http_headers, "authorization", 0, {"authorization", CodexPooler.PoolerFixtures.api_key_fixture(setup.pool, %{scope: model_serving_scope()}).authorization}), else: http_headers
      response = Req.post!("http://127.0.0.1:#{port}#{@path}", json: body, headers: http_headers, retry: false, receive_timeout: @budget)
      requests = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)

      if directory = System.get_env("TOOL_IDENTITY_EVIDENCE") do
        File.write!(Path.join(directory, "#{mode}-#{topology}-#{lifecycle}-#{fault}.json"), CodexPooler.JSON.encode!(%{mode: mode, topology: topology, remote_owner_verified: topology == :remote, http_status: response.status, request_count: length(requests), statuses: Enum.map(requests, & &1.status), codes: Enum.map(requests, & &1.last_error_code), predecessor_shapes: Enum.map(requests, &get_in(&1.request_metadata, ["client_resend", "predecessor_shape"])), attempt_diagnostics: Enum.map(Repo.all(from(a in Attempt, where: a.request_id in ^Enum.map(requests, & &1.id))), fn attempt -> %{network_error: attempt.network_error_code, failure: Map.take(attempt.response_metadata["transport_failure"] || %{}, ~w(phase reason_code transport_signal termination_source)), observation: Map.take(attempt.response_metadata["native_client_retry_observation"] || %{}, ~w(output_item_done_count terminal_seen terminal_candidate_seen))} end), http_provider_calls: FakeUpstream.http_request_count(upstream), attempt_count: Repo.aggregate(from(a in Attempt, where: a.request_id in ^Enum.map(requests, & &1.id)), :count), retry_links: Repo.aggregate(RequestClientRetryLink, :count)}))
      end

      assert_fallback(lifecycle, fault, response, requests, original, upstream)
      if legacy, do: assert({:ok, _} = Accounting.finalize_reserved_request_failure(legacy.request, %{last_error_code: "owner_drained"}))
    end
  end

  defp provider_reply(lifecycle, release) do
    frames = [%{"type" => "response.created", "response" => %{"id" => "resp_synthetic_live", "status" => "in_progress"}}, %{"type" => "response.output_text.delta", "delta" => "synthetic"}, %{"type" => "response.failed", "response" => %{"status" => "failed", "error" => %{"code" => "server_error"}}}]
    frames = if lifecycle == :completed_cut, do: List.replace_at(frames, 1, %{"type" => "response.output_item.done", "output_index" => 0, "item" => %{"id" => "msg_synthetic", "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic completed output"}]}}), else: frames
    if lifecycle in [:stream_cut, :completed_cut], do: FakeUpstream.websocket_text_frames_then_abrupt_close(Enum.map(Enum.take(frames, 2), &CodexPooler.JSON.encode!/1)), else: FakeUpstream.barrier_websocket_frames(Enum.map(frames, &CodexPooler.JSON.encode!/1), notify: self(), release_ref: release)
  end

  defp assert_concurrent_aliases(setup, body, original, mode, fault) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn = Repo.get_by!(CodexTurn, request_id: original.id)
    session = Repo.get!(CodexSession, turn.codex_session_id)
    opts = RequestOptions.build(%{transport: "http_sse", codex_session: session, api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch}, @path, body)
    {:ok, claim} = NativeHttpTurnIdentity.request_claim(opts, body)
    attrs = %{endpoint: @path, transport: "http_sse", codex_session: session, correlation_id: claim.key, original_request_claim: claim.key, native_http_tool_claims: claim.tool_continuation_claims, native_client_retry_witness: claim.native_client_retry_witness, native_http_semantic_turn_key: claim.semantic_turn_key, runtime_revocation_epoch: auth.api_key.runtime_revocation_epoch, request_metadata: %{"native_http_claim_arm" => "tool_continuation"}}
    if fault == :epoch_after_wait, do: epoch_after_wait(setup, body, auth, attrs, mode), else: concurrent_reservations(setup, body, original, mode, auth, attrs)
  end

  defp concurrent_reservations(setup, body, original, mode, auth, attrs) do
    parent = self()
    release = make_ref()
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      for lane <- 1..2 do
        task = Task.Supervisor.async_nolink(supervisor, fn -> alias_actor(parent, release, lane, auth, setup.model, body, attrs) end)

        {task, Process.monitor(task.pid)}
      end

    backends =
      for _ <- 1..2 do
        assert_receive {:alias_backend, lane, backend, pid}, @budget
        {lane, backend, pid}
      end

    assert backends |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 2
    for {_, _, pid} <- backends, do: send(pid, {:release_alias, release})

    results =
      for {task, monitor} <- tasks do
        result = Task.await(task, @budget)
        assert_receive {:DOWN, ^monitor, :process, _, :normal}, @budget
        result
      end

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, %{code: :duplicate_request}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Repo.aggregate(RequestClientRetryLink, :count) == 1
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
    assert Repo.exists?(from l in RequestClientRetryLink, where: l.predecessor_request_id == ^original.id and l.successor_request_id == ^winner.request.id)
    assert {:ok, _} = Accounting.finalize_reserved_request_failure(winner.request, %{last_error_code: "owner_drained"})

    if directory = System.get_env("TOOL_IDENTITY_EVIDENCE") do
      File.write!(Path.join(directory, "#{mode}-concurrent.json"), CodexPooler.JSON.encode!(%{independent_backend_count: 2, reserved: 1, refused: 1, durable_links: 1, original_provider_attempts: 1, successor_provider_attempts: 0}))
    end
  end

  defp alias_actor(parent, release, lane, auth, model, body, attrs) do
    Sandbox.unboxed_run(Repo, fn -> Repo.checkout(fn -> alias_actor_checked(parent, release, lane, auth, model, body, attrs) end) end)
  end

  defp alias_actor_checked(parent, release, lane, auth, model, body, attrs) do
    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(parent, {:alias_backend, lane, backend, self()})

    receive do
      {:release_alias, ^release} -> Accounting.reserve(auth, model, body, attrs)
    after
      @budget -> flunk("alias writer release missing")
    end
  end

  defp epoch_after_wait(setup, body, auth, attrs, mode) do
    parent = self()
    release = make_ref()
    supervisor = start_supervised!(Task.Supervisor)

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> epoch_holder_actor(setup, attrs, parent, release) end)

    holder_monitor = Process.monitor(holder.pid)
    assert_receive {:epoch_locked, holder_backend, holder_pid}, @budget

    waiter =
      Task.Supervisor.async_nolink(supervisor, fn -> epoch_waiter_actor(parent, auth, setup.model, body, attrs) end)

    waiter_monitor = Process.monitor(waiter.pid)
    assert_receive {:epoch_waiter, waiter_backend}, @budget
    refute waiter_backend == holder_backend
    blocked = wait_for_backend_block(holder_backend, waiter_backend, System.monotonic_time(:millisecond) + 2000)

    if not blocked do
      rows = Repo.query!("SELECT pid, wait_event_type, wait_event, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = ANY($1::integer[])", [[holder_backend, waiter_backend]]).rows
      if directory = System.get_env("TOOL_IDENTITY_EVIDENCE"), do: File.write!(Path.join(directory, "#{mode}-epoch-block-diagnostic.json"), CodexPooler.JSON.encode!(%{rows: rows, waiter_alive: Process.alive?(waiter.pid)}))
    end

    send(holder_pid, {:advance_epoch, release})
    assert {:ok, _} = Task.await(holder, @budget)
    result = Task.await(waiter, @budget)
    assert {:error, %{code: :api_key_runtime_epoch_stale}} = result
    assert blocked
    assert_receive {:DOWN, ^holder_monitor, :process, _, :normal}, @budget
    assert_receive {:DOWN, ^waiter_monitor, :process, _, :normal}, @budget
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert Repo.aggregate(RequestClientRetryLink, :count) == 0
    if directory = System.get_env("TOOL_IDENTITY_EVIDENCE"), do: File.write!(Path.join(directory, "#{mode}-epoch-after-wait.json"), CodexPooler.JSON.encode!(%{independent_backend_count: 2, actual_block_observed: true, stale_epoch_refused: true, successor_rows: 0, durable_links: 0}))
  end

  defp epoch_holder_actor(setup, attrs, parent, release) do
    Sandbox.unboxed_run(Repo, fn -> Repo.transaction(fn -> hold_epoch(setup, attrs, parent, release) end) end)
  end

  defp epoch_waiter_actor(parent, auth, model, body, attrs) do
    Sandbox.unboxed_run(Repo, fn -> Repo.checkout(fn -> epoch_waiter(parent, auth, model, body, attrs) end) end)
  end

  defp epoch_waiter(parent, auth, model, body, attrs) do
    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(parent, {:epoch_waiter, backend})
    Accounting.reserve(auth, model, body, attrs)
  end

  defp hold_epoch(setup, attrs, parent, release) do
    Repo.one!(from session in CodexSession, where: session.id == ^attrs.codex_session.id, lock: "FOR UPDATE")
    Repo.one!(from k in CodexPooler.Access.APIKey, where: k.id == ^setup.api_key.id, lock: "FOR UPDATE")
    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(parent, {:epoch_locked, backend, self()})

    receive do
      {:advance_epoch, ^release} -> Repo.update_all(from(k in CodexPooler.Access.APIKey, where: k.id == ^setup.api_key.id), inc: [runtime_revocation_epoch: 1])
    after
      @budget -> flunk("epoch writer release missing")
    end
  end

  defp wait_for_backend_block(holder, waiter, deadline) do
    [[blocked]] = Repo.query!("WITH RECURSIVE waits(pid, path) AS (SELECT unnest(pg_blocking_pids($2::integer)), ARRAY[$2::integer] UNION ALL SELECT next.pid, waits.path || waits.pid FROM waits CROSS JOIN LATERAL unnest(pg_blocking_pids(waits.pid)) AS next(pid) WHERE NOT waits.pid = ANY(waits.path) AND cardinality(waits.path) < 8) SELECT EXISTS(SELECT 1 FROM waits WHERE pid = $1::integer)", [holder, waiter]).rows

    cond do
      blocked -> true
      System.monotonic_time(:millisecond) < deadline -> wait_for_backend_block(holder, waiter, deadline)
      true -> false
    end
  end

  defp create_legacy_conflicting_root(setup, body, original) do
    turn = Repo.get_by!(CodexTurn, request_id: original.id)
    session = Repo.get!(CodexSession, turn.codex_session_id)
    opts = RequestOptions.build(%{transport: "http_sse", codex_session: session, api_key_runtime_epoch: setup.api_key.runtime_revocation_epoch}, @path, body)
    {:ok, claim} = NativeHttpTurnIdentity.request_claim(opts, body)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    # Real legacy admission: the old HTTP writer carried its primary/witness,
    # but no cross-transport tool aliases. Do not manufacture request rows.
    {:ok, reserved} = Accounting.reserve(auth, setup.model, body, %{endpoint: @path, transport: "http_sse", codex_session: session, correlation_id: claim.key, native_client_retry_witness: claim.native_client_retry_witness, runtime_revocation_epoch: auth.api_key.runtime_revocation_epoch, request_metadata: %{"native_http_claim_arm" => "tool_continuation"}})
    reserved
  end

  defp alter_fallback(:expired, body, original, _setup) do
    past = DateTime.add(DateTime.utc_now(), -31, :second)
    Repo.update_all(from(r in Request, where: r.id == ^original.id), set: [completed_at: past])
    Repo.update_all(from(a in Attempt, where: a.request_id == ^original.id), set: [completed_at: past])
    Repo.update_all(from(t in CodexTurn, where: t.request_id == ^original.id), set: [completed_at: past])
    body
  end

  defp alter_fallback(:epoch, body, _original, setup) do
    Repo.update_all(from(k in CodexPooler.Access.APIKey, where: k.id == ^setup.api_key.id), inc: [runtime_revocation_epoch: 1])
    body
  end

  defp alter_fallback(:epoch_typed, body, original, setup), do: alter_fallback(:epoch, body, original, setup) |> Map.put("type", "response.create")
  defp alter_fallback(:epoch_typed_marked, body, original, setup), do: alter_fallback(:epoch_typed, body, original, setup) |> put_in(["client_metadata", "ws_request_header_x_openai_internal_codex_responses_lite"], "true")
  defp alter_fallback(:null_type, body, _original, _setup), do: Map.put(body, "type", nil)
  defp alter_fallback(:null_marker, body, _original, _setup), do: put_in(body, ["client_metadata", "ws_request_header_x_openai_internal_codex_responses_lite"], nil)
  defp alter_fallback(:changed_output, body, _original, _setup), do: put_in(body, ["input", Elixir.Access.at(-1), "output"], "changed synthetic result")

  defp alter_fallback(:late_async, body, _original, _setup) do
    metadata = body["client_metadata"]["x-codex-turn-metadata"] |> CodexPooler.JSON.decode!() |> Map.put("workspaces", %{"/synthetic/repository" => %{"has_changes" => true}})
    put_in(body, ["client_metadata", "x-codex-turn-metadata"], CodexPooler.JSON.encode!(metadata))
  end

  defp alter_fallback(_fault, body, _original, _setup), do: body

  defp assert_fallback(_lifecycle, :multiple_roots, response, requests, _original, upstream) do
    assert response.status == 409
    assert length(requests) == 2
    assert FakeUpstream.http_request_count(upstream) == 0
    assert Repo.aggregate(RequestClientRetryLink, :count) == 0
  end

  defp assert_fallback(lifecycle, fault, response, requests, _original, upstream) when lifecycle == :live or fault in [:expired, :epoch, :epoch_typed, :epoch_typed_marked] do
    assert response.status == 409
    assert FakeUpstream.http_request_count(upstream) == 0
    assert length(requests) == 1
  end

  defp assert_fallback(_lifecycle, fault, response, requests, original, upstream) do
    assert response.status == 200
    assert FakeUpstream.http_request_count(upstream) == 1
    assert length(requests) == 2
    successor = Enum.find(requests, &(&1.id != original.id))
    linked? = Repo.exists?(from link in RequestClientRetryLink, where: link.predecessor_request_id == ^original.id and link.successor_request_id == ^successor.id)
    assert linked? == fault not in [:changed_output, :other_key, :null_marker, :null_type]
    if fault not in [:changed_output, :other_key, :null_marker, :null_type], do: assert(successor.request_metadata["client_resend"]["predecessor_request_id"] == original.id)
    for request <- requests, do: assert(Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 1)
  end
end
