defmodule CodexPoolerWeb.V1.ResponsesSseRolloutDrainTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistry
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, RolloutDrain}
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport.VirtualDeadline
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Endpoint
  alias Ecto.Adapters.SQL.Sandbox
  alias Plug.Adapters.Test.Conn, as: TestConn

  @public_path "/v1/responses"
  @response_id "resp_v1_rollout_drain"

  defmodule RaisingChunkAdapter do
    @moduledoc false
    defdelegate send_chunked(state, status, headers), to: TestConn
    defdelegate send_resp(state, status, headers, body), to: TestConn
    defdelegate read_req_body(state, opts), to: TestConn
    defdelegate get_peer_data(state), to: TestConn
    defdelegate get_http_protocol(state), to: TestConn
    def chunk(_state, _body), do: raise(ArgumentError, "synthetic downstream writer failure")
  end

  defmodule PausingHeadersAdapter do
    @moduledoc false
    defdelegate send_resp(state, status, headers, body), to: TestConn
    defdelegate read_req_body(state, opts), to: TestConn
    defdelegate get_peer_data(state), to: TestConn
    defdelegate get_http_protocol(state), to: TestConn
    defdelegate chunk(state, body), to: TestConn

    def send_chunked(state, status, headers) do
      send(state.test_parent, {:headers_held, self(), state.test_ref})

      receive do
        {:release_headers, ref} when ref == state.test_ref ->
          TestConn.send_chunked(state, status, headers)
      end
    end
  end

  # Cutoffs use the injected clock; the real relay and settlement finish on signals.
  @drain_timeout_ms 5_000
  @await_timeout_ms 15_000
  # `RolloutDrain`'s default deadline margin reserves a full owner call budget
  # (tens of seconds) before the poll deadline, which production's 85 s budget
  # absorbs but a test-sized budget does not: left at the default, the whole
  # wait collapses to the deadline floor. Reserve a small margin instead so the
  # drain actually waits for the stream it just signalled.
  @drain_options [deadline_margin_ms: 100, deadline_floor_ms: 50]

  setup do
    stream_registry = :"deferred-stream-registry-#{System.unique_integer([:positive])}"
    activity_registry = :"rollout-drain-activity-#{System.unique_integer([:positive])}"
    drain_name = :"rollout-drain-#{System.unique_integer([:positive])}"

    start_supervised!({DeferredStreamRegistry, name: stream_registry})
    start_supervised!({ActivityRegistry, name: activity_registry})

    start_supervised!(
      Supervisor.child_spec(
        {RolloutDrain,
         [
           name: drain_name,
           activity_registry: activity_registry,
           stream_registry: stream_registry
         ]},
        id: {RolloutDrain, drain_name}
      )
    )

    # Deferred streams register through the configured server name, so this
    # test's streams land in its own registry instead of the global one.
    previous_registry_config = Application.get_env(:codex_pooler, DeferredStreamRegistry)
    Application.put_env(:codex_pooler, DeferredStreamRegistry, server_name: stream_registry)

    on_exit(fn ->
      if previous_registry_config do
        Application.put_env(:codex_pooler, DeferredStreamRegistry, previous_registry_config)
      else
        Application.delete_env(:codex_pooler, DeferredStreamRegistry)
      end
    end)

    {:ok, drain_name: drain_name, stream_registry: stream_registry}
  end

  test "a rollout drain settles an in-flight deferred SSE stream and releases its reservation",
       %{conn: conn, drain_name: drain_name, stream_registry: stream_registry} do
    release_ref = make_ref()

    # provenance: observed findings issue 129 (native Responses SSE
    # created/delta prefix held open across a rollout; payload values invented)
    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([created_event(), delta_event()],
          barrier_after: 2,
          notify: self(),
          release_ref: release_ref,
          done: false
        )
      )

    setup = gateway_setup(upstream)
    parent = self()
    session_key = "v1-rollout-drain-session-#{System.unique_integer([:positive])}"

    # A sessioned turn is the case the drain has to settle correctly: the
    # request carries a CodexSession and CodexTurn, so the drain must leave the
    # turn interrupted rather than failed.
    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_key)
        |> post(@public_path, stream_payload(setup))
      end)

    assert_receive {:fake_upstream_chunk_barrier, 2, upstream_pid, ^release_ref},
                   @await_timeout_ms

    stream_entry = await_registered_stream(stream_registry)
    :ok = WebsocketRolloutDrainSupport.await_visible_http_turn!(stream_entry, @await_timeout_ms)

    {response, summary} =
      WebsocketRolloutDrainSupport.drain_http_request(
        request_task,
        drain_options(drain_name),
        @await_timeout_ms
      )

    assert %{
             result: :ok,
             http_streams_seen: 1,
             http_streams_completed: 1,
             http_streams_aborted: 0,
             http_streams_failed: 0
           } = summary

    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    assert response.status == 200

    # The client keeps the ordinary interrupted-stream contract: the events it
    # already received, then the same sanitized synthetic terminal an ordinary
    # interruption emits.
    assert stream_event_types(response.resp_body) == [
             "response.created",
             "response.output_text.delta",
             "error"
           ]

    request = latest_request(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.response_status_code == 499
    assert request.last_error_code == "owner_drained"
    assert %DateTime{} = request.completed_at

    assert [attempt] = Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert attempt.status == "failed"
    assert attempt.network_error_code == "owner_drained"
    assert %DateTime{} = attempt.completed_at

    # The registry carried the identifiers the drain needs to reason about the
    # stream it signalled.
    assert stream_entry.request_id == request.id
    assert stream_entry.attempt_id == attempt.id

    # A drained turn is interrupted, not failed: the upstream did nothing wrong.
    # Until now this half of the drain contract was asserted only on the
    # bridge/owner path.
    assert %CodexTurn{
             status: "interrupted",
             error_code: "owner_drained",
             final_attempt_id: final_attempt_id,
             completed_at: %DateTime{}
           } = Repo.get_by!(CodexTurn, request_id: request.id)

    assert final_attempt_id == attempt.id

    assert ledger_count(request.id, "reservation") == 1
    assert ledger_count(request.id, "release") == 1
    assert ledger_count(request.id, "settlement") == 1
    assert open_request_count(setup.pool.id) == 0
    assert open_attempt_count(setup.pool.id) == 0

    refute response.resp_body =~ "owner_drained"

    # The post-visible drain is already correct and must stay that way: one
    # synthetic terminal, the public `server_error` code, and a summary that
    # says so.
    summary = attempt.response_metadata["public_openai_responses_stream"]
    assert summary["visible_seen"] == true
    assert summary["synthetic_terminal_sent"] == true
    assert error_event_codes(response.resp_body) == ["server_error"]
  end

  test "a rollout drain before any relayed byte still ends the stream with a terminal error",
       %{conn: conn, drain_name: drain_name, stream_registry: stream_registry} do
    release_ref = make_ref()

    # provenance: observed findings issue 159 (six driven /v1/responses turns
    # drained after the upstream SSE headers and before any relayed event, each
    # recorded visible_seen=false, created_seen=false, terminal_class=none,
    # synthetic_terminal_sent=false). The upstream sends SSE headers and then
    # nothing, which is exactly the observed pre-visible window.
    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref,
          done: false
        )
      )

    setup = gateway_setup(upstream)
    parent = self()
    session_key = "v1-rollout-drain-pre-visible-#{System.unique_integer([:positive])}"

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_key)
        |> post(@public_path, stream_payload(setup))
      end)

    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref},
                   @await_timeout_ms

    _stream_entry = await_registered_stream(stream_registry)

    {response, summary} =
      WebsocketRolloutDrainSupport.drain_http_request(
        request_task,
        drain_options(drain_name),
        @await_timeout_ms
      )

    assert %{
             result: :ok,
             http_streams_seen: 1,
             http_streams_completed: 1,
             http_streams_aborted: 0,
             http_streams_failed: 0
           } = summary

    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    # The status is already committed by `send_chunked/2` before the deferred
    # stream runs, so the only signal left for the client is a terminal event.
    assert response.status == 200

    assert stream_event_types(response.resp_body) == ["error"]
    assert error_event_codes(response.resp_body) == ["server_error"]

    request = latest_request(setup.pool.id)
    assert request.status == "failed"
    assert request.response_status_code == 499
    assert request.last_error_code == "owner_drained"

    assert [attempt] = Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert attempt.network_error_code == "owner_drained"

    summary = attempt.response_metadata["public_openai_responses_stream"]
    assert summary["visible_seen"] == false
    assert summary["created_seen"] == false
    assert summary["synthetic_terminal_sent"] == true

    assert %CodexTurn{status: "interrupted", error_code: "owner_drained"} =
             Repo.get_by!(CodexTurn, request_id: request.id)

    # The drain is our own lifecycle event; its vocabulary stays owner-side.
    refute response.resp_body =~ "owner_drained"
  end

  test "a stream that already completed is not finalized again by a later drain", %{
    conn: conn,
    drain_name: drain_name
  } do
    upstream =
      start_upstream(
        # provenance: observed findings issue 129 (ordinary completed public
        # Responses SSE turn; payload values invented)
        FakeUpstream.sse_stream([created_event(), delta_event(), completed_event()])
      )

    setup = gateway_setup(upstream)

    response = conn |> auth(setup) |> post(@public_path, stream_payload(setup))

    assert response.status == 200
    assert response.resp_body =~ "event: response.completed\n"

    request = latest_request(setup.pool.id)
    assert request.status == "succeeded"

    assert %{result: :ok, http_streams_seen: 0} =
             RolloutDrain.start_drain(drain_options(drain_name))

    assert Repo.reload!(request).status == "succeeded"
    assert ledger_count(request.id, "settlement") == 1
    assert open_request_count(setup.pool.id) == 0
  end

  test "an in-budget SSE response completes normally after rollout drain starts", context do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [created_event(), delta_event(), completed_event()],
          barrier_after: 2,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        context.conn |> auth(setup) |> post(@public_path, stream_payload(setup))
      end)

    assert_receive {:fake_upstream_chunk_barrier, 2, upstream_pid, ^release_ref},
                   @await_timeout_ms

    await_registered_stream(context.stream_registry)
    deadline = WebsocketRolloutDrainSupport.start_virtual_deadline(self())

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: context.drain_name, timeout_ms: 5_000, deadline_margin_ms: 0] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, _}, @await_timeout_ms
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    response = Task.await(request_task, @await_timeout_ms)
    VirtualDeadline.advance(deadline, 200)
    summary = Task.await(drain_task, @await_timeout_ms)

    assert stream_event_types(response.resp_body) == [
             "response.created",
             "response.output_text.delta",
             "response.completed"
           ]

    assert latest_request(setup.pool.id).status == "succeeded"
    assert summary.http_streams_completed == 1
    assert summary.http_streams_failed == 0
  end

  test "HTTP admitted after drain is refused before reservation or upstream dispatch", context do
    upstream = start_upstream(FakeUpstream.sse_stream([completed_event()]))
    setup = gateway_setup(upstream)
    assert %{result: :ok} = RolloutDrain.start_drain(drain_options(context.drain_name))

    for path <- [@public_path, "/backend-api/codex/responses"], stream? <- [false, true] do
      response =
        build_conn()
        |> auth(setup)
        |> post(path, Map.put(stream_payload(setup), "stream", stream?))

      assert response.status == 503
      assert %{"error" => %{"code" => "owner_drained"}} = json_response(response, 503)
    end

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
    assert FakeUpstream.requests(upstream) == []
    assert build_conn() |> post(@public_path, stream_payload(setup)) |> Map.fetch!(:status) == 401
    assert build_conn() |> get("/session?optional=1") |> Map.fetch!(:status) == 200
  end

  test "pre-visible Chat drain emits an explicit terminal error", context do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref,
          done: false
        )
      )

    setup = gateway_setup(upstream)
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        context.conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{
          "model" => setup.model.exposed_model_id,
          "messages" => [%{"role" => "user", "content" => "synthetic drain request"}],
          "stream" => true
        })
      end)

    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref},
                   @await_timeout_ms

    await_registered_stream(context.stream_registry)

    {response, summary} =
      WebsocketRolloutDrainSupport.drain_http_request(
        request_task,
        drain_options(context.drain_name),
        @await_timeout_ms
      )

    assert %{http_streams_completed: 1} = summary
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert response.status == 200
    assert response.resp_body =~ "server_error"
    assert latest_request(setup.pool.id).last_error_code == "owner_drained"
    refute response.resp_body =~ "owner_drained"
  end

  for cutoff_before_reservation? <- [false, true] do
    @cutoff_before_reservation cutoff_before_reservation?
    test "admitted work joins original cutoff with pre-reservation cutoff=#{cutoff_before_reservation?}",
         context do
      assert_admitted_cutoff(context, @cutoff_before_reservation)
    end
  end

  for fault <- [:relay_raise, :finalization_raise] do
    @fault fault
    test "drain summary records real #{@fault} as failed and preserves original fault", context do
      assert_fault_summary(context, @fault)
    end
  end

  defp assert_fault_summary(context, fault) do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([created_event(), completed_event()],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref,
          # The gateway tears the upstream request down while the relay is
          # raising, so the released tail may meet a closed client.
          on_client_close: :expected,
          owner: "responses_sse_rollout_drain_test:fault_#{fault}"
        )
      )

    setup = gateway_setup(upstream)
    parent = self()
    CodexPooler.TestAppEnv.restore_on_exit(:settlement_pricing_test_fault)

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        conn = build_conn() |> auth(setup)
        conn = TestConn.conn(conn, :post, @public_path, stream_payload(setup))

        conn =
          if fault == :relay_raise do
            {_adapter, state} = conn.adapter
            %{conn | adapter: {RaisingChunkAdapter, state}}
          else
            conn
          end

        try do
          Endpoint.call(conn, Endpoint.init([]))
          :unexpected_success
        rescue
          exception -> {:raised, root_exception(exception).__struct__}
        end
      end)

    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref},
                   @await_timeout_ms

    await_registered_stream(context.stream_registry)
    deadline = WebsocketRolloutDrainSupport.start_virtual_deadline(self())

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: context.drain_name, timeout_ms: 1_000, deadline_margin_ms: 0] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, _}, @await_timeout_ms

    if fault == :finalization_raise do
      Application.put_env(
        :codex_pooler,
        :settlement_pricing_test_fault,
        {setup.pool.id, %DBConnection.ConnectionError{message: "synthetic settlement failure"}}
      )
    end

    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert {:raised, exception_module} = Task.await(request_task, @await_timeout_ms)

    assert exception_module ==
             if(fault == :relay_raise, do: ArgumentError, else: DBConnection.ConnectionError)

    VirtualDeadline.advance(deadline, 200)

    assert %{
             result: :error,
             http_streams_seen: 1,
             http_streams_completed: 0,
             http_streams_failed: 1,
             http_streams_aborted: 0
           } = Task.await(drain_task, @await_timeout_ms)
  end

  defp root_exception(%Plug.Conn.WrapperError{reason: reason}), do: root_exception(reason)
  defp root_exception(exception), do: exception

  test "a deferred closure registering after the cutoff is interrupted immediately", context do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref,
          done: false
        )
      )

    setup = gateway_setup(upstream)
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        conn = build_conn() |> auth(setup)
        conn = TestConn.conn(conn, :post, @public_path, stream_payload(setup))
        {_adapter, state} = conn.adapter
        state = Map.merge(state, %{test_parent: parent, test_ref: release_ref})
        Endpoint.call(%{conn | adapter: {PausingHeadersAdapter, state}}, [])
      end)

    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref},
                   @await_timeout_ms

    assert_receive {:headers_held, request_pid, ^release_ref}, @await_timeout_ms
    assert DeferredStreamRegistry.streams(name: context.stream_registry) == []
    deadline = WebsocketRolloutDrainSupport.start_virtual_deadline(self())

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: context.drain_name, timeout_ms: 1_000, deadline_margin_ms: 0] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, _}, @await_timeout_ms
    VirtualDeadline.advance(deadline, 1_000)
    assert_receive {:rollout_drain_deadline_wait, ^deadline, _}, @await_timeout_ms
    send(request_pid, {:release_headers, release_ref})
    response = Task.await(request_task, @await_timeout_ms)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert stream_event_types(response.resp_body) == ["error"]
    VirtualDeadline.advance(deadline, 200)

    assert %{http_streams_seen: 1, http_streams_completed: 1} =
             Task.await(drain_task, @await_timeout_ms)

    assert latest_request(setup.pool.id).last_error_code == "owner_drained"
  end

  test "a stale drain token cannot interrupt the next HTTP request on the same process",
       context do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([created_event(), completed_event()],
          barrier_after: 1,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        first = build_conn() |> auth(setup) |> post(@public_path, stream_payload(setup))
        send(parent, {:first_complete, self(), first.status})

        receive do
          {:next_request, old_token} ->
            send(self(), DeferredStreamRegistry.drain_message(old_token))
            second = build_conn() |> auth(setup) |> post(@public_path, stream_payload(setup))

            {stream_event_types(second.resp_body),
             receive do
               {:gateway_stream_drain, ^old_token, :owner_drained} -> :old_token_untouched
             after
               0 -> :old_token_consumed
             end}
        end
      end)

    assert_receive {:fake_upstream_chunk_barrier, 1, first_upstream_pid, ^release_ref},
                   @await_timeout_ms

    %{token: old_token} = await_registered_stream(context.stream_registry)
    send(first_upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert_receive {:first_complete, request_pid, 200}, @await_timeout_ms
    assert DeferredStreamRegistry.streams(name: context.stream_registry) == []
    send(request_pid, {:next_request, old_token})

    assert_receive {:fake_upstream_chunk_barrier, 1, second_upstream_pid, ^release_ref},
                   @await_timeout_ms

    %{token: new_token} = await_registered_stream(context.stream_registry)
    refute old_token == new_token
    send(second_upstream_pid, {:fake_upstream_release_chunk, release_ref})

    assert {["response.created", "response.completed"], :old_token_untouched} =
             Task.await(request_task, @await_timeout_ms)
  end

  test "HTTP SSE and websocket owner consume the same cutoff before HTTP settlement margin",
       context do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref,
          done: false
        )
      )

    setup = gateway_setup(upstream)
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        build_conn() |> auth(setup) |> post(@public_path, stream_payload(setup))
      end)

    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref},
                   @await_timeout_ms

    await_registered_stream(context.stream_registry)
    owner_key = Ecto.UUID.generate()
    start_supervised!({WebsocketRolloutDrainSupport.WaitingOwner, key: owner_key, parent: self()})
    deadline = WebsocketRolloutDrainSupport.start_virtual_deadline(self())

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: context.drain_name, timeout_ms: 1_000, deadline_margin_ms: 200] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    assert_receive {:rollout_drain_begin_wait, ^owner_key, 1}, @await_timeout_ms
    assert_receive {:rollout_drain_deadline_wait, ^deadline, 200}, @await_timeout_ms
    assert_receive {:rollout_drain_deadline_wait, ^deadline, 200}, @await_timeout_ms
    VirtualDeadline.advance(deadline, 600)
    assert_receive {:rollout_drain_deadline_wait, ^deadline, 200}, @await_timeout_ms
    assert_receive {:rollout_drain_deadline_wait, ^deadline, 200}, @await_timeout_ms
    assert [%{status: :active}] = DeferredStreamRegistry.streams(name: context.stream_registry)
    VirtualDeadline.advance(deadline, 200)
    assert_receive {:rollout_drain_owner_stopped, ^owner_key, :aborted, 1}, @await_timeout_ms
    assert_receive {:rollout_drain_deadline_wait, ^deadline, 200}, @await_timeout_ms
    response = Task.await(request_task, @await_timeout_ms)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert stream_event_types(response.resp_body) == ["error"]
    VirtualDeadline.advance(deadline, 200)

    assert %{turns_aborted: 1, http_streams_completed: 1} =
             Task.await(drain_task, @await_timeout_ms)
  end

  defp assert_admitted_cutoff(context, cutoff_before_reservation?) do
    release_ref = make_ref()

    # The drain ends the client path before the held tail is released, so the
    # fake's later tail write meets a closed client by design (findings#226).
    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([created_event(), completed_event()],
          barrier_after: 1,
          notify: self(),
          release_ref: release_ref,
          on_client_close: :expected,
          owner: "responses_sse_rollout_drain:admitted_cutoff"
        )
      )

    setup = gateway_setup(upstream)
    parent = self()
    barrier_ref = make_ref()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        Process.put(
          {CodexPooler.Gateway.Runtime.Service, :runtime_authorization_barrier},
          {parent, barrier_ref, {:reserve, :before}}
        )

        build_conn() |> auth(setup) |> post(@public_path, stream_payload(setup))
      end)

    assert_receive {:runtime_authorization_barrier, ^barrier_ref, :reserve, :before, request_pid},
                   @await_timeout_ms

    deadline = WebsocketRolloutDrainSupport.start_virtual_deadline(self())

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: context.drain_name, timeout_ms: 1_000, deadline_margin_ms: 0] ++
            WebsocketRolloutDrainSupport.deadline_options(deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, ^deadline, _}, @await_timeout_ms
    VirtualDeadline.advance(deadline, if(cutoff_before_reservation?, do: 1_000, else: 600))
    assert_receive {:rollout_drain_deadline_wait, ^deadline, _}, @await_timeout_ms
    send(request_pid, {:runtime_authorization_release, barrier_ref})

    if cutoff_before_reservation? do
      response = Task.await(request_task, @await_timeout_ms)
      assert response.status == 503
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
      assert FakeUpstream.requests(upstream) == []
      assert FakeUpstream.sse_outcomes(upstream) == []
      VirtualDeadline.advance(deadline, 200)
      assert %{http_streams_seen: 0} = Task.await(drain_task, @await_timeout_ms)
    else
      assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref},
                     @await_timeout_ms

      await_registered_stream(context.stream_registry)

      VirtualDeadline.advance(deadline, 400)
      assert_receive {:rollout_drain_deadline_wait, ^deadline, _}, @await_timeout_ms
      response = Task.await(request_task, @await_timeout_ms)
      # Release only once the handler has observed the client close on its own
      # socket; releasing on the FIN's heels can let one tail write succeed on
      # a half-closed socket and record nothing.
      assert_receive {:fake_upstream_client_gone, 1, ^upstream_pid, ^release_ref},
                     @await_timeout_ms

      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
      assert List.last(stream_event_types(response.resp_body)) == "error"
      VirtualDeadline.advance(deadline, 200)

      assert %{http_streams_seen: 1, http_streams_completed: 1} =
               Task.await(drain_task, @await_timeout_ms)

      assert latest_request(setup.pool.id).last_error_code == "owner_drained"

      # The held tail (chunk 2) really met the closed client: the fake records
      # exactly one expected client close for this owner, so the comment above
      # is load-bearing rather than narrative (findings#226).
      assert_receive {:fake_upstream_client_closed, 2, ^upstream_pid, ^release_ref},
                     @await_timeout_ms

      assert [
               %{
                 outcome: :client_closed_expected,
                 owner: "responses_sse_rollout_drain:admitted_cutoff",
                 chunk_index: 2
               }
             ] = FakeUpstream.sse_outcomes(upstream)
    end
  end

  defp drain_options(drain_name) do
    [name: drain_name, timeout_ms: @drain_timeout_ms] ++ @drain_options
  end

  defp stream_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "synthetic rollout drain stream request",
      "stream" => true
    }
  end

  defp created_event do
    {"response.created",
     %{
       "type" => "response.created",
       "response" => %{"id" => @response_id, "status" => "in_progress"}
     }}
  end

  defp delta_event do
    {"response.output_text.delta",
     %{
       "type" => "response.output_text.delta",
       "response_id" => @response_id,
       "output_index" => 0,
       "content_index" => 0,
       "delta" => "visible before the rollout drain"
     }}
  end

  defp completed_event do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => @response_id,
         "status" => "completed",
         "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
       }
     }}
  end

  defp await_registered_stream(registry) do
    await_registered_stream(registry, System.monotonic_time(:millisecond) + @await_timeout_ms)
  end

  # Registration happens inside the connection process as the deferred closure
  # starts, and no message announces it, so this reads the registry against a
  # wall-clock budget. Spinning the reads instead would exhaust a fixed attempt
  # count in milliseconds and fail on scheduling order rather than behavior.
  defp await_registered_stream(registry, deadline_ms) do
    case DeferredStreamRegistry.streams(name: registry) do
      [%{} = entry] ->
        entry

      [] ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("deferred stream never registered")
        else
          receive do
          after
            5 -> :ok
          end

          await_registered_stream(registry, deadline_ms)
        end
    end
  end

  defp stream_event_types(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first) do
        [event] -> [event]
        _missing -> []
      end
    end)
  end

  # The public error frame's own code, read back off the wire. The summary says
  # a synthetic terminal was sent; this says which code the client actually got.
  defp error_event_codes(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&(&1 =~ ~r/^event: error$/m))
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/^data: (.+)$/m, block, capture: :all_but_first) do
        [data] -> [CodexPooler.JSON.decode!(data)["code"]]
        _missing -> []
      end
    end)
  end

  defp latest_request(pool_id) do
    Repo.one!(
      from request in Request,
        where: request.pool_id == ^pool_id,
        order_by: [desc: request.admitted_at],
        limit: 1
    )
  end

  defp ledger_count(request_id, entry_kind) do
    Repo.aggregate(
      from(entry in LedgerEntry,
        where: entry.request_id == ^request_id and entry.entry_kind == ^entry_kind
      ),
      :count
    )
  end

  defp open_request_count(pool_id) do
    Repo.aggregate(
      from(request in Request,
        where: request.pool_id == ^pool_id and request.status in ["accepted", "in_progress"]
      ),
      :count
    )
  end

  defp open_attempt_count(pool_id) do
    Repo.aggregate(
      from(attempt in Attempt,
        join: request in Request,
        on: request.id == attempt.request_id,
        where: request.pool_id == ^pool_id and attempt.status in ["queued", "in_progress"]
      ),
      :count
    )
  end
end
