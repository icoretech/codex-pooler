defmodule CodexPoolerWeb.CodexResponsesSocketAPIKeyLifecycleTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures, only: [committed_bootstrap_owner_fixture!: 0]

  import CodexPooler.PoolerFixtures,
    only: [
      active_api_key_fixture: 0,
      active_api_key_fixture: 2,
      model_fixture: 2,
      pool_fixture: 1
    ]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @api_key_close {1008, "api key is no longer active"}
  @endpoint "/backend-api/codex/responses"
  @invalidations [:deleted, :never_existing, :expired, :pool_inactive]

  # Failure-detection budgets for messages that are already decided when they
  # are awaited; a green run never waits them out.
  @capability_release_budget_ms 15_000
  @event_detection_budget_ms 15_000

  # The expiry check is a real timer on the socket, so these tests spend real
  # time: the expiry has to lie after the authentication, session start and
  # event handling that precede it, and those take tens of milliseconds under
  # N=4 scheduling pressure.
  @expiry_lead_ms 700
  @expiry_detection_budget_ms 15_000

  # A reread blocked on a row lock fails after this bound instead of waiting,
  # which is how a database error reaches the event-prompted reread here.
  @reread_lock_timeout_ms 100

  test "a live key keeps authorizing frames on a busy socket" do
    setup = active_api_key_fixture()

    state =
      api_key_socket_state(setup.api_key.id, setup.pool.id, 0, %{tasks: MapSet.new([self()])})

    {state, _queued} = submit_queued!(state, native_continuation_payload("live-key-content"))

    refute state.api_key_revoked?
    refute state.api_key_close_sent?
  end

  for invalidation <- @invalidations do
    test "a #{invalidation} key refuses the next frame on an idle socket and closes with 1008" do
      invalidation = unquote(invalidation)
      {state, setup} = socket_for(invalidation)
      invalidate!(invalidation, setup)
      marker = "idle-#{invalidation}-content"

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_in(
                 {native_create_payload(marker), [opcode: :text]},
                 state
               )

      assert closed_state.api_key_revoked?
      assert closed_state.api_key_close_sent?
      assert MapSet.size(closed_state.tasks) == 0
      assert :queue.is_empty(closed_state.queued_response_payloads)
      refute inspect(closed_state) =~ marker
    end

    test "a #{invalidation} key refuses the next frame on a busy socket and closes after the drain" do
      invalidation = unquote(invalidation)
      task_pid = self()
      {state, setup} = socket_for(invalidation, %{tasks: MapSet.new([task_pid])})
      {state, capability} = queue_before_invalidation(invalidation, state)
      invalidate!(invalidation, setup)
      marker = "busy-#{invalidation}-later-content"

      assert {:ok, revoked_state} =
               CodexResponsesSocket.handle_in(
                 {native_continuation_payload(marker), [opcode: :text]},
                 state
               )

      assert revoked_state.api_key_revoked?
      refute revoked_state.api_key_close_sent?
      assert revoked_state.tasks == MapSet.new([task_pid])
      assert :queue.is_empty(revoked_state.queued_response_payloads)
      assert_capability_released!(capability)
      refute inspect(revoked_state) =~ marker

      final_frame = ~s({"type":"response.done","response":{"id":"resp_lifecycle_final"}})

      assert {:push, {:text, ^final_frame}, draining_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_chunk, task_pid, final_frame},
                 revoked_state
               )

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_done, task_pid, :ok},
                 draining_state
               )

      assert closed_state.api_key_close_sent?
      assert MapSet.size(closed_state.tasks) == 0
    end
  end

  describe "event-driven close of an idle socket" do
    test "deleting the key closes the socket from its api_key_deleted event" do
      setup = active_api_key_fixture()
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      relay_pool_events!(setup.pool.id)

      assert {:ok, _deleted} = Access.delete_api_key(owner_scope(setup.api_key), setup.api_key)
      event = assert_pool_event!("api_key_deleted")

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info({Events, event}, state)

      assert closed_state.api_key_revoked?
      assert closed_state.api_key_close_sent?
    end

    test "disabling the Pool closes the socket from its pool_status_updated event" do
      setup = active_api_key_fixture()
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      relay_pool_events!(setup.pool.id)

      assert {:ok, _pool} =
               Pools.change_pool_status(owner_scope(setup.api_key), setup.pool, "disabled")

      event = assert_pool_event!("pool_status_updated")

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info({Events, event}, state)

      assert closed_state.api_key_close_sent?
    end

    test "disabling the Pool through the Pool edit workflow closes the socket from its pool_updated event" do
      setup = active_api_key_fixture()
      scope = owner_scope(setup.api_key)
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      relay_pool_events!(setup.pool.id)

      assert {:ok, %{status: "disabled"}} =
               PoolWorkflow.update_pool_with_related_settings(
                 scope,
                 setup.pool,
                 pool_edit_attrs(setup, %{"status" => "disabled"})
               )

      event = assert_pool_event!("pool_updated")

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info({Events, event}, state)

      assert closed_state.api_key_close_sent?
    end

    test "renaming the Pool through the Pool edit workflow does not reread authorization" do
      setup = active_api_key_fixture()
      scope = owner_scope(setup.api_key)
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      relay_pool_events!(setup.pool.id)

      assert {:ok, %{status: "active"}} =
               PoolWorkflow.update_pool_with_related_settings(
                 scope,
                 setup.pool,
                 pool_edit_attrs(setup, %{"name" => "Renamed lifecycle Pool"})
               )

      event = assert_pool_event!("pool_updated")

      # Any reread refuses a key whose expiry has passed, so the socket staying
      # open proves the rename did not query the key row.
      put_expiry!(setup.api_key, DateTime.add(DateTime.utc_now(), -1, :second))

      assert {:ok, open_state} = CodexResponsesSocket.handle_info({Events, event}, state)
      refute open_state.api_key_revoked?

      assert {:stop, :normal, @api_key_close, _closed_state} =
               CodexResponsesSocket.handle_in(
                 {native_create_payload("renamed-pool-content"), [opcode: :text]},
                 open_state
               )
    end

    test "archiving and deleting the Pool closes the socket from its pool_deleted event" do
      setup = active_api_key_fixture()
      scope = owner_scope(setup.api_key)
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      assert {:ok, archived} = Pools.change_pool_status(scope, setup.pool, "archived")
      relay_pool_events!(setup.pool.id)

      assert {:ok, _deleted} = Pools.delete_archived_pool(scope, archived, archived.slug)
      event = assert_pool_event!("pool_deleted")

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info({Events, event}, state)

      assert closed_state.api_key_close_sent?
    end

    test "moving the expiry into the past closes the socket from its api_key_updated event" do
      setup = active_api_key_fixture()
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      relay_pool_events!(setup.pool.id)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      # The operator form submits the key's status with every edit.
      assert {:ok, _updated} =
               Access.update_api_key(owner_scope(setup.api_key), setup.api_key, %{
                 expires_at: past,
                 status: "active"
               })

      event = assert_pool_event!("api_key_updated")

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info({Events, event}, state)

      assert closed_state.api_key_close_sent?
    end
  end

  describe "moving the key to another Pool" do
    test "an operator move closes an idle socket on the previous Pool from its api_key_updated event" do
      setup = active_api_key_fixture()
      scope = owner_scope(setup.api_key)
      target_pool = pool_for!(scope)
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      relay_pool_events!(setup.pool.id)

      # The operator form submits the key's status with every edit.
      assert {:ok, %APIKey{runtime_revocation_epoch: 1}} =
               Access.update_api_key(scope, setup.api_key, %{
                 pool_id: target_pool.id,
                 status: "active"
               })

      event = assert_pool_event!("api_key_updated")
      assert event.pool_id == setup.pool.id

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info({Events, event}, state)

      assert closed_state.api_key_disabling_epoch == 1
      assert closed_state.api_key_close_sent?
    end

    test "a Pool wizard move refuses the next frame on a busy socket and closes after the drain" do
      task_pid = self()
      setup = active_api_key_fixture()
      scope = owner_scope(setup.api_key)
      target_pool = pool_for!(scope)

      state =
        api_key_socket_state(setup.api_key.id, setup.pool.id, 0, %{tasks: MapSet.new([task_pid])})

      assert :ok = Access.assign_api_keys_to_pool(scope, target_pool, [setup.api_key.id])

      assert {:ok, revoked_state} =
               CodexResponsesSocket.handle_in(
                 {native_continuation_payload("moved-later-content"), [opcode: :text]},
                 state
               )

      assert revoked_state.api_key_revoked?
      assert revoked_state.api_key_disabling_epoch == 1
      refute revoked_state.api_key_close_sent?
      assert :queue.is_empty(revoked_state.queued_response_payloads)

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info(
                 {:codex_response_done, task_pid, :ok},
                 revoked_state
               )

      assert closed_state.api_key_close_sent?
    end
  end

  describe "time-based expiry of an idle socket" do
    test "a socket opened with an expiring key closes at the expiry without a client frame" do
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      expires_at = DateTime.add(DateTime.utc_now(), @expiry_lead_ms, :millisecond)
      put_expiry!(setup.api_key, expires_at)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      {:ok, state} =
        CodexResponsesSocket.init(%{
          auth: auth,
          opts: %{
            request_id: "lifecycle-expiry",
            accepted_turn_state: "lifecycle-expiry",
            client_ip: "127.0.0.1"
          }
        })

      try do
        assert {:stop, :normal, @api_key_close, closed_state} =
                 close_on_expiry_check!(state, expires_at)

        assert closed_state.api_key_close_sent?
        assert FakeUpstream.count(upstream) == 0
      after
        CodexResponsesSocket.terminate(:closed, state)
      end
    end

    test "an operator update that brings the expiry forward re-arms the check from the durable row" do
      setup = active_api_key_fixture()
      state = api_key_socket_state(setup.api_key.id, setup.pool.id, 0)
      relay_pool_events!(setup.pool.id)
      expires_at = DateTime.add(DateTime.utc_now(), @expiry_lead_ms, :millisecond)

      assert {:ok, _updated} =
               Access.update_api_key(owner_scope(setup.api_key), setup.api_key, %{
                 expires_at: expires_at
               })

      event = assert_pool_event!("api_key_updated")
      assert {:ok, armed_state} = CodexResponsesSocket.handle_info({Events, event}, state)
      refute armed_state.api_key_revoked?

      assert {:stop, :normal, @api_key_close, closed_state} =
               close_on_expiry_check!(armed_state, expires_at)

      assert closed_state.api_key_close_sent?
    end
  end

  describe "a reread prompted by an event or the expiry check" do
    test "a database error keeps the socket open and arms a retry that decides later" do
      %{scope: scope, pool: pool, api_key: api_key} = committed_api_key_fixture!()
      state = api_key_socket_state(api_key.id, pool.id, 0)
      holder = hold_api_key_row!(api_key.id)

      # Scoped to the test's sandbox transaction, so the reread's own
      # transaction (a savepoint here) fails on the held row instead of waiting.
      SQL.query!(Repo, "SET LOCAL lock_timeout = '#{@reread_lock_timeout_ms}ms'", [])

      assert {:ok, retrying_state} =
               CodexResponsesSocket.handle_info({Events, api_key_event(pool, api_key)}, state)

      refute retrying_state.api_key_revoked?
      refute retrying_state.api_key_close_sent?
      assert %{token: token, timer: timer, attempt: 1} = retrying_state.api_key_reread_retry
      assert is_reference(token)
      assert Process.read_timer(timer) > 0

      assert {:ok, :released} = release_api_key_row!(holder)

      assert {:ok, _deleted} =
               Sandbox.unboxed_run(Repo, fn -> Access.delete_api_key(scope, api_key.id) end)

      assert {:stop, :normal, @api_key_close, closed_state} =
               CodexResponsesSocket.handle_info({:api_key_reread_retry, token}, retrying_state)

      assert closed_state.api_key_close_sent?
    end
  end

  describe "claim and reservation refusals delivered as task results" do
    test "a claim refused for a deleted key latches revocation instead of rendering an error frame" do
      setup = active_api_key_fixture()
      model = model_fixture(setup.pool, %{exposed_model_id: "gpt-lifecycle-claim"})
      assert {:ok, _deleted} = Access.delete_api_key(owner_scope(setup.api_key), setup.api_key)

      assert {:error, reason} =
               Accounting.claim_websocket_turn(auth_context(setup), model, %{
                 correlation_id: "lifecycle-claim-#{System.unique_integer([:positive])}",
                 endpoint: @endpoint,
                 requested_model: model.exposed_model_id,
                 runtime_revocation_epoch: 0
               })

      assert_refusal_latches_and_drains!(setup, reason)
    end

    test "a reservation refused for an expired key latches revocation instead of rendering an error frame" do
      setup = active_api_key_fixture()
      model = model_fixture(setup.pool, %{exposed_model_id: "gpt-lifecycle-reserve"})
      put_expiry!(setup.api_key, DateTime.add(DateTime.utc_now(), -1, :second))

      assert {:error, reason} =
               Accounting.reserve(
                 auth_context(setup),
                 model,
                 %{"model" => model.exposed_model_id, "input" => "lifecycle"},
                 %{
                   correlation_id: "lifecycle-reserve-#{System.unique_integer([:positive])}",
                   endpoint: @endpoint,
                   requested_model: model.exposed_model_id,
                   runtime_revocation_epoch: 0
                 }
               )

      assert_refusal_latches_and_drains!(setup, reason)
    end
  end

  # The refused turn settles while another admitted turn is still running, so
  # the socket has to latch and wait for that drain rather than answer the
  # refused turn with an error frame and stay open. The refused task reported
  # its activity first, as a real response task does, so its delivery can be
  # settled.
  defp assert_refusal_latches_and_drains!(setup, reason) do
    admitted_task = self()
    refused_task = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
    refused_token = make_ref()

    state =
      api_key_socket_state(setup.api_key.id, setup.pool.id, 0, %{
        tasks: MapSet.new([refused_task, admitted_task])
      })

    assert {:ok, state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_activity, refused_task, refused_token},
               state
             )

    result = {:socket_response_result, :local_complete, {:error, reason}}

    assert {:ok, revoked_state} =
             CodexResponsesSocket.handle_info({:codex_response_done, refused_task, result}, state)

    assert revoked_state.api_key_revoked?
    refute revoked_state.api_key_close_sent?

    # A refusal has no terminal to deliver, so the socket settles the refused
    # task's delivery itself. The task stays tracked until that acknowledgement
    # goes out; without it the task would wait forever, count as admitted
    # work, and hold the 1008 close open.
    assert_received {:websocket_response_delivery_complete, ^refused_task, ^refused_token}

    assert {:ok, delivered_state} =
             CodexResponsesSocket.handle_info(
               {:websocket_response_delivery_complete, refused_task, refused_token},
               revoked_state
             )

    assert delivered_state.tasks == MapSet.new([admitted_task])
    refute Map.has_key?(delivered_state.response_task_activities, refused_task)
    refute delivered_state.api_key_close_sent?

    assert {:stop, :normal, @api_key_close, closed_state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, admitted_task, :ok},
               delivered_state
             )

    assert closed_state.api_key_close_sent?
    send(refused_task, :stop)
  end

  # The check fires at the node's reading of the expiry, while the durable
  # authorization compares it with the database clock; a database clock a
  # little behind the node authorizes that first check and re-arms it, so the
  # close is awaited across re-armed checks within the detection budget.
  defp close_on_expiry_check!(state, expires_at) do
    deadline = System.monotonic_time(:millisecond) + @expiry_lead_ms + @expiry_detection_budget_ms
    await_expiry_close!(state, expires_at, deadline)
  end

  defp await_expiry_close!(state, expires_at, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    assert_receive {:api_key_expiry_check, _token} = message, remaining
    refute DateTime.compare(DateTime.utc_now(), expires_at) == :lt

    case CodexResponsesSocket.handle_info(message, state) do
      {:ok, %{api_key_revoked?: false} = rearmed_state} ->
        await_expiry_close!(rearmed_state, expires_at, deadline)

      result ->
        result
    end
  end

  defp socket_for(invalidation, overrides \\ %{})

  defp socket_for(:never_existing, overrides) do
    state = api_key_socket_state(Ecto.UUID.generate(), Ecto.UUID.generate(), 0, overrides)
    {state, nil}
  end

  defp socket_for(_invalidation, overrides) do
    setup = active_api_key_fixture()
    {api_key_socket_state(setup.api_key.id, setup.pool.id, 0, overrides), setup}
  end

  # A never-existing key has no moment at which it was valid, so nothing can
  # be queued ahead of its refusal.
  defp queue_before_invalidation(:never_existing, state), do: {state, nil}

  defp queue_before_invalidation(invalidation, state) do
    {state, queued} =
      submit_queued!(state, native_continuation_payload("queued-before-#{invalidation}"))

    {state, monitor_capability(queued)}
  end

  defp invalidate!(:never_existing, nil), do: :ok

  defp invalidate!(:deleted, setup),
    do: assert({:ok, _deleted} = Access.delete_api_key(owner_scope(setup.api_key), setup.api_key))

  defp invalidate!(:expired, setup),
    do: put_expiry!(setup.api_key, DateTime.add(DateTime.utc_now(), -1, :second))

  defp invalidate!(:pool_inactive, setup) do
    assert {:ok, %{status: "disabled"}} =
             Pools.change_pool_status(owner_scope(setup.api_key), setup.pool, "disabled")
  end

  # Moves the expiry without an operator event, the way the clock crossing it does.
  defp put_expiry!(api_key, expires_at) do
    assert {1, _rows} =
             Repo.update_all(from(key in APIKey, where: key.id == ^api_key.id),
               set: [expires_at: expires_at]
             )
  end

  defp pool_edit_attrs(setup, overrides) do
    Map.merge(
      %{
        "name" => setup.pool.name,
        "status" => "active",
        "routing_strategy" => "bridge_ring",
        "api_key_ids" => [setup.api_key.id]
      },
      overrides
    )
  end

  defp pool_for!(scope) do
    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "socket-lifecycle-#{System.unique_integer([:positive])}",
               name: "Socket lifecycle target Pool"
             })

    pool
  end

  # Operator broadcasts use `broadcast_from/4`, which skips the process that
  # made the change, so a separate subscriber carries the real event back.
  defp relay_pool_events!(pool_id) do
    parent = self()

    relay =
      spawn(fn ->
        :ok = Events.subscribe_pool(pool_id, "pools")
        send(parent, {:pool_event_relay_ready, self()})
        relay_pool_event_loop(parent)
      end)

    on_exit(fn -> Process.exit(relay, :kill) end)
    assert_receive {:pool_event_relay_ready, ^relay}, @event_detection_budget_ms
    relay
  end

  defp relay_pool_event_loop(parent) do
    receive do
      {Events, %Events.Event{}} = message ->
        send(parent, {:relayed_pool_event, message})
        relay_pool_event_loop(parent)
    end
  end

  defp assert_pool_event!(reason) do
    assert_receive {:relayed_pool_event, {Events, %Events.Event{reason: ^reason} = event}},
                   @event_detection_budget_ms

    event
  end

  # The prompt is not the path under test in the database-error case, so the
  # event is the shape an operator edit of this key broadcasts.
  defp api_key_event(pool, api_key) do
    %Events.Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool.id,
      topics: ["pools"],
      reason: "api_key_updated",
      emitted_at: DateTime.utc_now(),
      payload: %{
        "api_key_id" => api_key.id,
        "pool_id" => pool.id,
        "runtime_revocation_epoch" => 0,
        "status" => "active"
      }
    }
  end

  # The key is committed so that another backend can hold its row. The
  # committed owner's registered removal takes the Pool, the key and the audit
  # rows its delete writes.
  defp committed_api_key_fixture! do
    %{user: owner} = committed_bootstrap_owner_fixture!()

    Sandbox.unboxed_run(Repo, fn ->
      pool = pool_fixture(%{created_by_user_id: owner.id})

      %{api_key: api_key} =
        active_api_key_fixture(pool, %{
          created_by_user_id: owner.id,
          display_name: "Socket reread retry key"
        })

      %{scope: Scope.for_user(owner, ["instance_owner"]), pool: pool, api_key: api_key}
    end)
  end

  defp hold_api_key_row!(api_key_id) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> api_key_row_holder(parent, ref, api_key_id) end)
      end)

    assert_receive {:api_key_row_held, ^ref}, @event_detection_budget_ms
    %{task: task, ref: ref}
  end

  defp api_key_row_holder(parent, ref, api_key_id) do
    Repo.transaction(fn ->
      Repo.one!(
        from(key in APIKey,
          where: key.id == ^api_key_id,
          lock: "FOR UPDATE",
          select: key.id
        )
      )

      send(parent, {:api_key_row_held, ref})

      receive do
        {:release_api_key_row, ^ref} -> :released
      after
        @event_detection_budget_ms -> raise "the api_keys row holder was not released"
      end
    end)
  end

  defp release_api_key_row!(%{task: task, ref: ref}) do
    send(task.pid, {:release_api_key_row, ref})
    Task.await(task, @event_detection_budget_ms)
  end

  defp auth_context(setup) do
    %{
      pool: setup.pool,
      api_key: setup.api_key,
      api_key_id: setup.api_key.id,
      pool_id: setup.pool.id,
      key_prefix: setup.api_key.key_prefix
    }
  end

  defp owner_scope(api_key) do
    User
    |> Repo.get!(api_key.created_by_user_id)
    |> Scope.for_user(["instance_owner"])
  end

  defp api_key_socket_state(api_key_id, pool_id, captured_epoch, overrides) do
    Map.merge(
      %{
        opts:
          RequestOptions.for_websocket(%{})
          |> RequestOptions.put_runtime_context(api_key_runtime_epoch: captured_epoch),
        api_key_id: api_key_id,
        api_key_pool_id: pool_id,
        api_key_runtime_epoch: captured_epoch,
        api_key_revoked?: false,
        api_key_close_sent?: false,
        firewall_revoked?: false,
        firewall_close_sent?: false,
        tasks: MapSet.new(),
        task_monitors: %{},
        queued_response_payloads: :queue.new(),
        public_response_task_pid: nil,
        public_response_stream_id: nil,
        public_responses_websocket_state: nil,
        public_turn_task_done?: false,
        public_turn_owner_complete?: false,
        public_turn_aborted?: false,
        public_turn_output_committed?: false,
        native_turn_output_task_pids: MapSet.new(),
        auth: %{pool: %{id: pool_id}, api_key: %{id: api_key_id}}
      },
      overrides
    )
  end

  defp api_key_socket_state(api_key_id, pool_id, captured_epoch),
    do: api_key_socket_state(api_key_id, pool_id, captured_epoch, %{})

  # A real submission is the only way to reach the socket queue (findings#192).
  defp submit_queued!(state, payload) do
    queued_before = :queue.len(state.queued_response_payloads)

    assert {:ok, queued_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)

    assert queued_state.tasks == state.tasks
    assert :queue.len(queued_state.queued_response_payloads) == queued_before + 1

    assert %PreparedWebsocketFrame{} =
             queued = :queue.get_r(queued_state.queued_response_payloads)

    {queued_state, queued}
  end

  defp native_create_payload(marker) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => "gpt-test",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => marker}]
        }
      ]
    })
  end

  # A tool-result continuation is continuity-ordered, so a native socket queues
  # it behind the active task instead of starting it alongside.
  defp native_continuation_payload(output) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => "gpt-test",
      "previous_response_id" => "resp_fixture_anchor",
      "input" => [
        %{
          "type" => "function_call_output",
          "call_id" => "call_fixture_queued",
          "output" => output
        }
      ]
    })
  end

  defp monitor_capability(%PreparedWebsocketFrame{} = prepared) do
    server = prepared.provenance.capability.server
    {server, Process.monitor(server)}
  end

  defp assert_capability_released!(nil), do: :ok

  defp assert_capability_released!({server, monitor}) do
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, @capability_release_budget_ms
  end
end
