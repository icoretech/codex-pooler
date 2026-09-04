defmodule CodexPooler.Gateway.Transports.WebsocketVisibilityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.RequestReplay
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout_ms 15_000

  test "ordinary websocket stream query count does not grow after first visibility" do
    short = measure_stream(1)
    long = measure_stream(1_000)

    IO.puts("websocket visibility baseline #{inspect(%{short: short, long: long})}")
    assert long.queries <= short.queries + 2
    assert long.frames == 1_002
  end

  test "owner delivery query count does not grow after first visibility" do
    short = measure_stream(1, :owner)
    long = measure_stream(1_000, :owner)

    IO.puts("owner visibility measurements #{inspect(%{short: short, long: long})}")
    assert long.queries <= short.queries + 2
    assert long.frames == 1_002
  end

  test "rolled back visibility never becomes a reusable callback witness" do
    fixture = fixture()
    parent = self()
    observation = observation(fixture)

    writer =
      WebsocketRequestCallbacks.observing_writer(
        fn _frame -> send(parent, :visible_frame) end,
        observation
      )

    WebsocketRequestCallbacks.begin_request(fixture.request.id, fixture.attempt.id)

    try do
      assert {:error, :cancelled} =
               Repo.transaction(fn ->
                 writer.(Jason.encode!(%{"type" => "response.created"}))
                 Repo.rollback(:cancelled)
               end)

      assert drain_frames() == 1
      assert Repo.reload!(fixture.turn).first_visible_output_at == nil
      assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))
      writer.(Jason.encode!(%{"type" => "response.output_text.delta", "delta" => ""}))
      assert drain_frames() == 0
    after
      WebsocketRequestCallbacks.end_request()
    end
  end

  test "visibility fallback without a turn is not a committed witness" do
    fixture = fixture()
    Repo.delete!(fixture.turn)

    assert {:ok, :untracked} =
             SessionContinuity.authorize_codex_turn_visibility(fixture.request, fixture.attempt)
  end

  test "failed receive call clears its committed callback witness" do
    fixture = fixture()
    parent = self()
    observation = observation(fixture)
    observer = WebsocketRequestCallbacks.frame_observer(fixture.identity, observation)
    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames(frames(1)))
    on_exit(fn -> FakeUpstream.stop(upstream) end)

    request = %UpstreamWebsocketSession.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: "{}",
      timeouts:
        RequestOptions.for_websocket(%{receive_timeout_ms: @detection_timeout_ms}).timeout_config,
      request_id: fixture.request.id,
      attempt_id: fixture.attempt.id,
      frame_observer: observer,
      writer: fn _frame -> throw(:synthetic_writer_failure) end
    }

    assert catch_throw(UpstreamWebsocketSession.request_once(request)) ==
             :synthetic_writer_failure

    assert Repo.reload!(fixture.turn).first_visible_output_at

    fixture.attempt |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
    handler = "visibility-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, _, _ -> send(parent, {handler, 1}) end,
        nil
      )

    try do
      event = %{"type" => "response.output_text.delta", "delta" => ""}
      observer.(Jason.encode!(event), event)
      assert drain_queries(handler, []) != []
    after
      :telemetry.detach(handler)
    end
  end

  test "reused upstream process does not carry visibility into a stale next request" do
    first = fixture()
    stale = fixture()
    {:ok, _armed} = RequestReplay.arm(arm_input(stale))

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames(frames(2)))
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    session = start_supervised!(UpstreamWebsocketSession)

    assert {:ok, _result} = dispatch(upstream, first, session)
    assert drain_frames() == 4
    assert Repo.reload!(first.turn).first_visible_output_at

    assert {:ok, _result} = dispatch(upstream, stale, session)
    assert drain_frames() == 0
    assert Repo.reload!(stale.turn).first_visible_output_at == nil
  end

  test "arm holding the turn lock wins over a waiting first visible event" do
    committed = committed_fixture()
    {holder, waiter} = contend(committed, :arm, :visible)

    assert {:ok, _armed} = Task.await(holder, @detection_timeout_ms)
    assert {:error, :stale_generation} = Task.await(waiter, @detection_timeout_ms)
    assert unboxed(fn -> Repo.reload!(committed.turn).first_visible_output_at end) == nil
  end

  test "first visibility holding the turn lock prevents a waiting replay arm" do
    committed = committed_fixture()
    {holder, waiter} = contend(committed, :visible, :arm)

    assert :ok = Task.await(holder, @detection_timeout_ms)
    assert {:error, :ineligible} = Task.await(waiter, @detection_timeout_ms)
    assert unboxed(fn -> Repo.reload!(committed.turn).first_visible_output_at end)
  end

  defp measure_stream(deltas, topology \\ :direct) do
    fixture = fixture()
    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames(frames(deltas)))
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    parent = self()
    handler = "websocket-visibility-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _event, measurements, _metadata, _config ->
          send(parent, {handler, measurements.total_time})
        end,
        nil
      )

    started = System.monotonic_time(:microsecond)

    try do
      result =
        case topology do
          :direct -> dispatch(upstream, fixture)
          :owner -> dispatch_owner(upstream, fixture)
        end

      assert {:ok, _result} = result

      elapsed_us = System.monotonic_time(:microsecond) - started
      queries = drain_queries(handler, [])

      %{
        queries: length(queries),
        query_us: System.convert_time_unit(Enum.sum(queries), :native, :microsecond),
        elapsed_us: elapsed_us,
        frames: drain_frames()
      }
    after
      :telemetry.detach(handler)
    end
  end

  defp dispatch_owner(upstream, fixture) do
    {:ok, owner} =
      WebsocketOwnerSession.start_owner(
        codex_session_id: fixture.session.id,
        owner_lease_token: fixture.session.owner_lease_token,
        owner_instance_id: fixture.session.owner_instance_id,
        owner_renewal_ms: 60_000
      )

    Sandbox.allow(Repo, self(), owner)

    try do
      {:ok, downstream} =
        WebsocketOwnerSession.attach_downstream(owner, %{
          pid: self(),
          correlation_id: "visibility"
        })

      descriptor = %{
        semantic_turn_key: <<1::256>>,
        replay_claim_digest: <<2::256>>,
        authorization_snapshot: %{},
        request_id: fixture.request.id,
        codex_turn_id: fixture.turn.id,
        model_id: fixture.model.id,
        endpoint: fixture.request.endpoint,
        attempt_id: fixture.attempt.id,
        replay_generation: 0
      }

      :ok = WebsocketOwnerSession.prepare_next_replay_descriptor(owner, downstream, descriptor)

      WebsocketOwnerSession.submit_request(owner, downstream, %UpstreamWebsocketSession.Request{
        url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
        headers: [],
        payload: "{}",
        timeouts:
          RequestOptions.for_websocket(%{receive_timeout_ms: @detection_timeout_ms}).timeout_config,
        message_mapper: & &1,
        effective_serving_mode: "full",
        request_id: fixture.request.id,
        attempt_id: fixture.attempt.id,
        frame_observer:
          WebsocketRequestCallbacks.frame_observer(fixture.identity, observation(fixture))
      })
    after
      GenServer.stop(owner, :normal, @detection_timeout_ms)
    end
  end

  defp observation(fixture) do
    %{
      request_id: fixture.request.id,
      attempt_id: fixture.attempt.id,
      client_request_id: nil,
      mode: "full"
    }
  end

  defp dispatch(upstream, fixture, session \\ nil) do
    parent = self()

    options =
      %{receive_timeout_ms: @detection_timeout_ms}
      |> then(fn opts ->
        if session, do: Map.put(opts, :upstream_websocket_session, session), else: opts
      end)
      |> RequestOptions.for_websocket(%{"model" => "example-model"})

    UpstreamDispatch.websocket_request(%UpstreamDispatch.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "redacted",
      upstream_payload: "{}",
      identity: fixture.identity,
      accounting_request: fixture.request,
      accounting_attempt: fixture.attempt,
      routing_hint_authorized?: true,
      writer: fn _frame -> send(parent, :visible_frame) end,
      assignment_advertised?: false,
      request_options: options
    })
  end

  defp frames(deltas) do
    ([%{"type" => "response.created"}] ++
       List.duplicate(%{"type" => "response.output_text.delta", "delta" => ""}, deltas) ++
       [%{"type" => "response.completed", "response" => %{"id" => "resp_example"}}])
    |> Enum.map(&Jason.encode!/1)
  end

  defp drain_frames(count \\ 0) do
    receive do
      :visible_frame -> drain_frames(count + 1)
      {:websocket_owner_frame, "visibility", _epoch, {:data, _payload}} -> drain_frames(count + 1)
    after
      0 -> count
    end
  end

  defp drain_queries(handler, queries) do
    receive do
      {^handler, duration} -> drain_queries(handler, [duration | queries])
    after
      0 -> queries
    end
  end

  defp contend(fixture, first, second) do
    parent = self()
    barrier = make_ref()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> hold_turn(fixture, first, parent, barrier) end)
      end)

    assert_receive {^barrier, :locked, blocker_pid}, @detection_timeout_ms

    waiter =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, {barrier, :waiting, backend_pid()})
          operation(second, fixture)
        end)
      end)

    assert_receive {^barrier, :waiting, waiter_pid}, @detection_timeout_ms
    assert waiter_pid != blocker_pid

    try do
      unboxed(fn ->
        await_blocked(
          waiter_pid,
          blocker_pid,
          System.monotonic_time(:millisecond) + @detection_timeout_ms
        )
      end)
    after
      send(holder.pid, {barrier, :release})
    end

    {holder, waiter}
  end

  defp hold_turn(fixture, first, parent, barrier) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.one!(from turn in CodexTurn, where: turn.id == ^fixture.turn.id, lock: "FOR UPDATE")
        send(parent, {barrier, :locked, backend_pid()})

        receive do
          {^barrier, :release} -> operation(first, fixture)
        after
          @detection_timeout_ms -> flunk("turn lock barrier was not released")
        end
      end)

    result
  end

  defp operation(:arm, fixture), do: RequestReplay.arm(arm_input(fixture))

  defp operation(:visible, fixture),
    do: SessionContinuity.mark_codex_turn_visible(fixture.request, fixture.attempt)

  defp await_blocked(waiter, blocker, deadline) do
    %{rows: [[blockers, wait_type]]} =
      Repo.query!(
        "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid=$1",
        [waiter]
      )

    cond do
      blocker in blockers and wait_type == "Lock" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("distinct backend never blocked on the held turn")

      true ->
        await_blocked(waiter, blocker, deadline)
    end
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
    pid
  end

  defp unboxed(callback) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, callback) end)
    |> Task.await(@detection_timeout_ms)
  end

  defp committed_fixture do
    {:ok, fixture} = unboxed(fn -> Repo.transaction(&fixture/0) end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from entitlement in CodexPooler.Accounting.RequestReplayEntitlement,
            where: entitlement.request_id == ^fixture.request.id
        )

        Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)

        Repo.delete_all(
          from identity in UpstreamIdentity, where: identity.id == ^fixture.identity.id
        )
      end)
    end)

    fixture
  end

  defp fixture do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    auth = %{pool: pool, api_key: api_key}
    %{assignment: assignment, identity: identity} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{metadata: %{"source_assignment_ids" => [assignment.id]}})

    {:ok, session} =
      Websocket.start_codex_session(auth, %{accepted_turn_state: Ecto.UUID.generate()})

    request =
      request_fixture(auth, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil
      })

    options =
      RequestOptions.for_websocket(%{})
      |> RequestOptions.put_continuity(semantic_turn_key: <<1::256>>)

    {:ok, turn} = SessionContinuity.start_codex_turn(session, request, options)

    attempt =
      attempt_fixture(request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })
      |> Ecto.Changeset.change(model_id: model.id)
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      attempt_id: nil,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      model_id: model.id
    })
    |> Ecto.Changeset.change(source_event_id: "request:#{request.id}:reservation")
    |> Repo.update!()

    %{
      pool: pool,
      api_key: api_key,
      assignment: assignment,
      identity: identity,
      model: model,
      session: Repo.reload!(session),
      request: request,
      turn: turn,
      attempt: attempt
    }
  end

  defp arm_input(fixture) do
    %{
      api_key_id: fixture.api_key.id,
      pool_id: fixture.pool.id,
      codex_session_id: fixture.session.id,
      request_id: fixture.request.id,
      codex_turn_id: fixture.turn.id,
      eligible_attempt_id: fixture.attempt.id,
      api_key_runtime_epoch: fixture.api_key.runtime_revocation_epoch,
      model_id: fixture.model.id,
      model_identifier: fixture.model.exposed_model_id,
      endpoint: fixture.request.endpoint,
      semantic_turn_digest: <<1::256>>,
      replay_claim_digest: <<2::256>>,
      owner_instance_id: fixture.session.owner_instance_id,
      owner_lease_token: fixture.session.owner_lease_token,
      predecessor_epoch: 1,
      failure_reason: :client_disconnected,
      pre_visible_output: true
    }
  end
end
