defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerProtocolIntegrationTest do
  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.{PreparedContext, SelectedCandidateContext}
  alias CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @detection_timeout_ms 5_000
  @remote_node :"codex_pooler@protocol-owner.example"

  defmodule CancellationNodeClient do
    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    @remote_node :"codex_pooler@protocol-owner.example"

    @impl true
    def connected_app_nodes, do: [@remote_node]

    @impl true
    def app_node?(@remote_node), do: true

    @impl true
    def call_owner(node, module, function, args, _timeout) do
      downstream = Enum.find(args, &(is_map(&1) and is_pid(Map.get(&1, :pid))))
      send(downstream.pid, {:cancellation_node_call, self(), node, function})
      result = apply(module, function, args)
      send(downstream.pid, {:cancellation_node_call_complete, self(), node, function, result})
      result
    end
  end

  setup do
    reset_bootstrap_state_fixture!()
    auth = auth_fixture()

    previous_observation_setting =
      Application.get_env(:codex_pooler, :multi_agent_round_product_observation_enabled)

    on_exit(fn ->
      restore_observation_setting(previous_observation_setting)
    end)

    {:ok, auth: auth}
  end

  test "v1 mapper matrix preserves owner-local observations and exactly-once delivery", %{
    auth: auth
  } do
    Application.put_env(:codex_pooler, :multi_agent_round_product_observation_enabled, true)
    handler_id = attach_product_observer!()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    for {mapper, request_options_fun, mapper_fun} <- mapper_cases() do
      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(auth.pool)

      model =
        model_fixture(auth.pool, %{
          exposed_model_id: "protocol-#{mapper}-#{System.unique_integer([:positive])}"
        })

      quota_handler_id = attach_quota_commit_barrier!(identity.id)
      on_exit(fn -> :telemetry.detach(quota_handler_id) end)
      reset_at = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)
      rate_limit = Jason.encode!(rate_limit_event(reset_at))
      terminal = terminal_frame("resp_protocol_#{mapper}")
      duplicate_terminal = terminal_frame("resp_protocol_duplicate_#{mapper}")
      expected_rate_limit = mapper_fun.(rate_limit)
      expected_terminal = mapper_fun.(terminal)
      expected_duplicate_terminal = mapper_fun.(duplicate_terminal)
      release_ref = make_ref()
      result_release_ref = make_ref()

      upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([rate_limit, terminal]))

      %{session: session, lease_token: lease_token} = owner_session_fixture(auth, mapper)
      accounting = accounting_turn_fixture(auth, session, assignment, model, mapper)
      payload = websocket_payload(model.exposed_model_id)

      downstream_sender =
        terminal_barrier_downstream_sender(mapper, expected_terminal, release_ref)

      {:ok, owner} =
        start_owner(session,
          upstream: terminal_result_barrier_upstream(self(), result_release_ref),
          downstream_sender: downstream_sender,
          request_id: "request-#{mapper}"
        )

      assert {:ok, stable_downstream} =
               WebsocketOwnerSession.attach_downstream(
                 owner,
                 downstream_target("corr-#{mapper}")
               )

      reset_probe = bound_reset_probe(assignment, identity, model.exposed_model_id)
      parent = self()

      submitter =
        Task.async(fn ->
          request_options =
            request_options_fun.(
              owner_request_options(
                session,
                lease_token,
                public_turn_downstream(stable_downstream, mapper),
                reset_probe,
                payload: payload,
                request_id: accounting.request.correlation_id
              )
            )
            |> RequestOptions.put_transport(
              websocket_owner_submission_observer: fn ->
                send(parent, {:submission_observed, mapper, self()})
              end
            )

          {prepared_context, request} =
            runtime_dispatch_fixture(
              upstream,
              auth,
              assignment,
              identity,
              model,
              request_options,
              accounting,
              payload
            )

          finalized_websocket_request(prepared_context, request,
            notify: parent,
            capture_request_to: parent
          )
        end)

      assert_receive {:websocket_owner_harness_terminal_delivery_barrier, barrier_pid,
                      ^release_ref}

      assert Task.yield(submitter, 0) == nil
      assert FakeUpstream.count(upstream) == 1

      await_quota_commit!(quota_handler_id)
      :telemetry.detach(quota_handler_id)
      send(barrier_pid, {:websocket_owner_harness_release_terminal_delivery, release_ref})

      assert_receive {:websocket_owner_harness_terminal_delivered, ^release_ref}
      assert_receive {:terminal_result_barrier, result_pid, ^result_release_ref}

      assert %{active_turn: %{ref: active_turn_ref, terminal_forwarded?: true}} =
               :sys.get_state(owner)

      send(
        owner,
        {:websocket_owner_upstream_frame, active_turn_ref, expected_duplicate_terminal}
      )

      assert %{
               active_turn: %{
                 ref: ^active_turn_ref,
                 terminal_forwarded?: true,
                 pending_result: nil
               }
             } = :sys.get_state(owner)

      send(result_pid, {:release_terminal_result, result_release_ref})

      assert {:ok, %{status: 200, websocket_messages: []}} =
               Task.await(submitter, @detection_timeout_ms)

      assert_receive {:submission_observed, ^mapper, observer_pid}
      assert observer_pid == submitter.pid
      refute_received {:submission_observed, ^mapper, _duplicate}

      assert_receive {:websocket_owner_harness_request,
                      %WebsocketOwnerRequest{
                        version: 1,
                        mapper: ^mapper,
                        reset_probe: ^reset_probe,
                        upstream_identity_id: identity_id,
                        submission_notification?: true
                      }}

      assert identity_id == identity.id

      assert_receive {:websocket_owner_harness_node_call,
                      %{function: :remote_submit_request_v1, arity: 3}}

      refute_received {:websocket_owner_harness_node_call,
                       %{function: :remote_submit_request_v1, arity: 3}}

      expected_rate_limit_message =
        owner_data_message(mapper, stable_downstream, submitter.pid, expected_rate_limit)

      expected_terminal_message =
        owner_data_message(mapper, stable_downstream, submitter.pid, expected_terminal)

      expected_duplicate_terminal_message =
        owner_data_message(mapper, stable_downstream, submitter.pid, expected_duplicate_terminal)

      expected_complete_message = owner_complete_message(mapper, stable_downstream, submitter.pid)

      assert_receive ^expected_rate_limit_message
      assert_receive ^expected_terminal_message
      assert_receive ^expected_complete_message
      refute_received ^expected_terminal_message
      refute_received ^expected_duplicate_terminal_message
      refute_received ^expected_complete_message

      assert_product_observations()

      assert_quota_observation(identity, reset_at)
      assert_successful_accounting!(accounting)
      assert %{active_turn: nil} = :sys.get_state(owner)
    end
  end

  test "v1 owner preserves real upstream connection lifecycle metadata", %{auth: auth} do
    terminals =
      Enum.map([:fresh, :reused, :reconnected], fn kind ->
        terminal_frame("resp_connection_#{kind}")
      end)

    upstream =
      start_fake_upstream(
        {:sequence,
         Enum.map(terminals, fn terminal ->
           FakeUpstream.websocket_text_frames([terminal])
         end)}
      )

    identity = active_upstream_identity_fixture()

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, :metadata_lifecycle)

    {:ok, owner} = start_owner(session)

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("corr-connection-metadata")
             )

    connections =
      Enum.map(Enum.with_index(terminals, 1), fn {terminal, index} ->
        if index == 3 do
          assert :ok =
                   owner
                   |> :sys.get_state()
                   |> Map.fetch!(:upstream_pid)
                   |> UpstreamWebsocketSession.invalidate_connection()
        end

        payload = websocket_payload("connection-metadata-model")

        request_options =
          owner_request_options(session, lease_token, downstream, nil, payload: payload)

        request = dispatch_request(upstream, identity, request_options, nil, payload)

        assert {:ok, %{upstream_websocket_connection: connection}} = websocket_request(request)
        assert_receive {:websocket_owner_frame, "corr-connection-metadata", 1, {:data, ^terminal}}
        assert_receive {:websocket_owner_frame, "corr-connection-metadata", 1, :complete}
        connection
      end)

    assert [fresh, reused, reconnected] = connections
    assert Ecto.UUID.cast(fresh.lifecycle_id) == {:ok, fresh.lifecycle_id}
    assert fresh.generation == 1
    assert fresh.reused == false
    assert fresh.reconnected == false
    assert reused == %{fresh | reused: true}
    assert reconnected.lifecycle_id == fresh.lifecycle_id
    assert reconnected.generation == 2
    assert reconnected.reused == false
    assert reconnected.reconnected == true
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "v1 stale epoch is rejected before upstream submission", %{auth: auth} do
    upstream =
      start_fake_upstream(FakeUpstream.websocket_text_frames([terminal_frame("resp_stale")]))

    fixture = protocol_runtime_fixture(auth, :stale_epoch)
    {:ok, owner} = start_owner(fixture.session)

    assert {:ok, stale_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("corr-stale"))

    assert {:ok, active_downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("corr-active"))

    assert active_downstream.epoch == stale_downstream.epoch + 1

    assert :ok = WebsocketOwnerSession.push_downstream(owner, {:data, "active-epoch"})
    assert_receive {:websocket_owner_frame, "corr-active", 2, {:data, "active-epoch"}}
    refute_received {:websocket_owner_frame, "corr-stale", 1, _stale_payload}

    request_options =
      owner_request_options(fixture.session, fixture.lease_token, stale_downstream, nil,
        payload: fixture.payload,
        request_id: fixture.accounting.request.correlation_id
      )

    {prepared_context, request} =
      runtime_dispatch_fixture(
        upstream,
        auth,
        fixture.assignment,
        fixture.identity,
        fixture.model,
        request_options,
        fixture.accounting,
        fixture.payload
      )

    assert {:error, %{code: "duplicate_downstream", status: 409}} =
             finalized_websocket_request(prepared_context, request, [])

    assert FakeUpstream.count(upstream) == 0
    assert %{active_turn: nil, downstream: ^active_downstream} = :sys.get_state(owner)
    assert_failed_accounting!(fixture.accounting, "failed", "duplicate_downstream")
  end

  test "v1 cancellation watcher detaches an owner blocked in real upstream submission", %{
    auth: auth
  } do
    release_ref = make_ref()

    upstream =
      start_fake_upstream(
        FakeUpstream.timeout_mid_stream(
          "data: #{response_created_frame()}\n\n",
          notify: self(),
          release_ref: release_ref
        )
      )

    fixture = protocol_runtime_fixture(auth, :cancel)
    {:ok, owner} = start_owner(fixture.session)

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target("corr-cancel"))

    parent = self()

    request_options =
      owner_request_options(fixture.session, fixture.lease_token, downstream, nil,
        payload: fixture.payload,
        request_id: fixture.accounting.request.correlation_id,
        forwarder_opts: [node_client: CancellationNodeClient]
      )

    {prepared_context, request} =
      runtime_dispatch_fixture(
        upstream,
        auth,
        fixture.assignment,
        fixture.identity,
        fixture.model,
        request_options,
        fixture.accounting,
        fixture.payload
      )

    submitter =
      Task.async(fn -> finalized_websocket_request(prepared_context, request, notify: parent) end)

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, websocket_pid, ^release_ref}

    assert_receive {:websocket_owner_frame, "corr-cancel", 1, {:data, created_frame}}

    assert Jason.decode!(created_frame)["type"] == "response.created"
    assert FakeUpstream.count(upstream) == 1
    assert %{active_turn: %{task_pid: owner_task}} = :sys.get_state(owner)
    owner_task_ref = Process.monitor(owner_task)
    websocket_ref = Process.monitor(websocket_pid)

    assert {:ok, %{interrupted_turn_count: 1}} =
             Gateway.interrupt_codex_turn(fixture.session, request_options)

    Task.shutdown(submitter, :brutal_kill)

    assert_receive {:cancellation_node_call, watcher_pid, @remote_node,
                    :remote_cancel_downstream_v1}

    refute watcher_pid == submitter.pid

    assert_receive {:cancellation_node_call_complete, ^watcher_pid, @remote_node,
                    :remote_cancel_downstream_v1, :ok}

    refute_received {:cancellation_node_call, _duplicate, @remote_node,
                     :remote_cancel_downstream_v1}

    assert_receive {:DOWN, ^owner_task_ref, :process, ^owner_task, :shutdown},
                   @detection_timeout_ms

    assert_receive {:websocket_owner_frame, "corr-cancel", 1,
                    {:error, :client_disconnected, safe_payload}}

    assert safe_payload.code == "client_disconnected"
    assert_receive {:websocket_owner_frame, "corr-cancel", 1, :complete}
    assert %{active_turn: nil, downstream: nil} = :sys.get_state(owner)
    assert FakeUpstream.count(upstream) == 1

    assert_receive {:DOWN, ^websocket_ref, :process, ^websocket_pid, _reason},
                   @detection_timeout_ms

    refute_received {:websocket_owner_frame, "corr-cancel", 1, _duplicate}

    assert_failed_accounting!(fixture.accounting, "interrupted", "client_disconnected")
  end

  test "v1 pre-visible owner failure recovers requests without a bound reset probe", %{
    auth: auth
  } do
    for {kind, reset_probe} <- [absent: nil, unbound: ResetProbe.new()] do
      terminal = terminal_frame("resp_recovered_owner_#{kind}")
      recovery_upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([terminal]))
      release_ref = make_ref()
      correlation_id = "corr-pre-visible-recovery-#{kind}"
      parent = self()

      first_upstream = %{
        start: fn -> Agent.start_link(fn -> :ready end) end,
        send: fn _upstream_pid, request, _writer ->
          send(
            parent,
            {:pre_visible_owner_submit_started, self(), release_ref, request.reset_probe}
          )

          receive do
            {:release_pre_visible_owner_submit, ^release_ref} -> :ok
          end
        end,
        close: fn upstream_pid ->
          if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
        end
      }

      fixture =
        protocol_runtime_fixture(auth, "pre_visible_recovery_#{kind}", Atom.to_string(node()))

      {:ok, first_owner} = start_owner(fixture.session, upstream: first_upstream)

      assert {:ok, downstream} =
               WebsocketOwnerSession.attach_downstream(
                 first_owner,
                 downstream_target(correlation_id)
               )

      request_options =
        owner_request_options(
          fixture.session,
          fixture.lease_token,
          downstream,
          reset_probe,
          payload: fixture.payload,
          request_id: fixture.accounting.request.correlation_id
        )

      {prepared_context, request} =
        runtime_dispatch_fixture(
          recovery_upstream,
          auth,
          fixture.assignment,
          fixture.identity,
          fixture.model,
          request_options,
          fixture.accounting,
          fixture.payload
        )

      submitter =
        Task.async(fn ->
          finalized_websocket_request(prepared_context, request, [])
        end)

      assert_receive {:pre_visible_owner_submit_started, first_worker, ^release_ref, ^reset_probe}

      first_owner_ref = Process.monitor(first_owner)
      Process.exit(first_owner, :kill)
      assert_receive {:DOWN, ^first_owner_ref, :process, ^first_owner, :killed}
      send(first_worker, {:release_pre_visible_owner_submit, release_ref})

      assert_receive {:websocket_owner_runtime_recovered, ^correlation_id, 1,
                      %{websocket_owner_downstream: recovered_downstream}}

      assert recovered_downstream.correlation_id == downstream.correlation_id
      assert recovered_downstream.epoch == downstream.epoch

      assert_receive {:websocket_owner_frame, ^correlation_id, 1, {:data, ^terminal}}
      assert_receive {:websocket_owner_frame, ^correlation_id, 1, :complete}

      assert {:ok, %{status: 200, websocket_messages: []}} =
               Task.await(submitter, @detection_timeout_ms)

      assert FakeUpstream.count(recovery_upstream) == 1
      assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(fixture.session.id)
      assert recovered_owner != first_owner

      assert_replaced_owner_lease!(fixture.session, fixture.lease_token)
      assert_successful_accounting!(fixture.accounting)

      assert %{active_turn: nil, downstream: ^recovered_downstream} =
               :sys.get_state(recovered_owner)

      refute_received {:pre_visible_owner_submit_started, _duplicate_worker, ^release_ref}
      refute_received {:websocket_owner_runtime_recovered, ^correlation_id, 1, _duplicate}
    end
  end

  test "v1 bound reset probe prevents pre-visible owner recovery", %{auth: auth} do
    recovery_upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([]))
    release_ref = make_ref()
    parent = self()

    first_upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:bound_probe_owner_submit_started, self(), release_ref})

        receive do
          {:release_bound_probe_owner_submit, ^release_ref} -> :ok
        end
      end,
      close: fn upstream_pid ->
        if Process.alive?(upstream_pid), do: Agent.stop(upstream_pid)
      end
    }

    fixture = protocol_runtime_fixture(auth, :bound_probe, Atom.to_string(node()))

    {:ok, owner} = start_owner(fixture.session, upstream: first_upstream)

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(
               owner,
               downstream_target("corr-bound-probe")
             )

    reset_probe =
      bound_reset_probe(fixture.assignment, fixture.identity, fixture.model.exposed_model_id)

    request_options =
      owner_request_options(fixture.session, fixture.lease_token, downstream, reset_probe,
        payload: fixture.payload,
        request_id: fixture.accounting.request.correlation_id
      )

    assert ResetProbe.matches?(
             reset_probe,
             fixture.assignment.id,
             fixture.identity.id,
             request_options.routing.effective_model,
             RequestOptions.route_class(request_options)
           )

    {prepared_context, request} =
      runtime_dispatch_fixture(
        recovery_upstream,
        auth,
        fixture.assignment,
        fixture.identity,
        fixture.model,
        request_options,
        fixture.accounting,
        fixture.payload
      )

    submitter = Task.async(fn -> finalized_websocket_request(prepared_context, request, []) end)

    assert_receive {:bound_probe_owner_submit_started, first_worker, ^release_ref}
    first_worker_ref = Process.monitor(first_worker)
    owner_ref = Process.monitor(owner)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    send(first_worker, {:release_bound_probe_owner_submit, release_ref})
    assert_receive {:DOWN, ^first_worker_ref, :process, ^first_worker, _reason}

    assert {:error, %{code: "owner_crashed", status: 502}} =
             Task.await(submitter, @detection_timeout_ms)

    assert FakeUpstream.count(recovery_upstream) == 0
    assert_unchanged_owner_lease!(fixture.session, fixture.lease_token)
    refute_received {:websocket_owner_runtime_recovered, "corr-bound-probe", 1, _recovery}
    refute_received {:websocket_owner_frame, "corr-bound-probe", 1, _payload}
    assert_failed_accounting!(fixture.accounting, "failed", "owner_crashed")
  end

  test "v1 bound reset probe scope mismatches recover a missing owner", %{auth: auth} do
    for mismatch <- [:assignment, :identity, :model, :route_class] do
      terminal = terminal_frame("resp_reset_probe_mismatch_#{mismatch}")
      recovery_upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([terminal]))
      correlation_id = "corr-reset-probe-mismatch-#{mismatch}"

      fixture =
        protocol_runtime_fixture(
          auth,
          "reset_probe_mismatch_#{mismatch}",
          Atom.to_string(node())
        )

      {:ok, owner} = start_owner(fixture.session)

      assert {:ok, downstream} =
               WebsocketOwnerSession.attach_downstream(owner, downstream_target(correlation_id))

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

      reset_probe =
        fixture.assignment
        |> bound_reset_probe(fixture.identity, fixture.model.exposed_model_id)
        |> mismatch_reset_probe_scope(mismatch)

      request_options =
        owner_request_options(fixture.session, fixture.lease_token, downstream, reset_probe,
          payload: fixture.payload,
          request_id: fixture.accounting.request.correlation_id
        )

      refute ResetProbe.matches?(
               reset_probe,
               fixture.assignment.id,
               fixture.identity.id,
               request_options.routing.effective_model,
               RequestOptions.route_class(request_options)
             )

      {prepared_context, request} =
        runtime_dispatch_fixture(
          recovery_upstream,
          auth,
          fixture.assignment,
          fixture.identity,
          fixture.model,
          request_options,
          fixture.accounting,
          fixture.payload
        )

      assert {:ok, %{status: 200, websocket_messages: []}} =
               finalized_websocket_request(prepared_context, request, [])

      assert_receive {:websocket_owner_frame, ^correlation_id, 1, {:data, ^terminal}}
      assert_receive {:websocket_owner_frame, ^correlation_id, 1, :complete}
      assert FakeUpstream.count(recovery_upstream) == 1
      assert {:ok, recovered_owner} = WebsocketOwnerSession.lookup(fixture.session.id)

      assert %{active_turn: nil, downstream: ^downstream} =
               :sys.get_state(recovered_owner)

      assert_unchanged_owner_lease!(fixture.session, fixture.lease_token)
      assert_successful_accounting!(fixture.accounting)
      refute_received {:websocket_owner_runtime_recovered, ^correlation_id, 1, _duplicate}
    end
  end

  test "v1 exact bound reset probe suppresses missing owner recovery", %{auth: auth} do
    recovery_upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([]))
    correlation_id = "corr-exact-reset-probe-missing-owner"

    fixture =
      protocol_runtime_fixture(auth, :exact_reset_probe_missing_owner, Atom.to_string(node()))

    {:ok, owner} = start_owner(fixture.session)

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, downstream_target(correlation_id))

    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

    reset_probe =
      bound_reset_probe(fixture.assignment, fixture.identity, fixture.model.exposed_model_id)

    request_options =
      owner_request_options(fixture.session, fixture.lease_token, downstream, reset_probe,
        payload: fixture.payload,
        request_id: fixture.accounting.request.correlation_id
      )

    assert ResetProbe.matches?(
             reset_probe,
             fixture.assignment.id,
             fixture.identity.id,
             request_options.routing.effective_model,
             RequestOptions.route_class(request_options)
           )

    {prepared_context, request} =
      runtime_dispatch_fixture(
        recovery_upstream,
        auth,
        fixture.assignment,
        fixture.identity,
        fixture.model,
        request_options,
        fixture.accounting,
        fixture.payload
      )

    assert {:error, %{code: "owner_unavailable", status: 503}} =
             finalized_websocket_request(prepared_context, request, [])

    assert FakeUpstream.count(recovery_upstream) == 0
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(fixture.session.id)
    assert_unchanged_owner_lease!(fixture.session, fixture.lease_token)
    assert_failed_accounting!(fixture.accounting, "failed", "owner_unavailable")
    refute_received {:websocket_owner_runtime_recovered, ^correlation_id, 1, _recovery}
    refute_received {:websocket_owner_frame, ^correlation_id, 1, _payload}
  end

  test "v1 committed output failure probes once and never replays", %{auth: auth} do
    for kind <- [:raise, :throw, :exit] do
      created = response_created_frame()
      visible = output_delta_frame()
      expected_created = StreamProtocol.normalize_public_openai_responses_json_message(created)
      expected_visible = StreamProtocol.normalize_public_openai_responses_json_message(visible)
      correlation_id = "corr-post-visible-#{kind}"

      upstream =
        start_fake_upstream(
          FakeUpstream.websocket_sse_then_close([
            Jason.decode!(created),
            Jason.decode!(visible)
          ])
        )

      fixture = protocol_runtime_fixture(auth, :"post_visible_#{kind}")

      {:ok, owner} =
        start_owner(fixture.session, upstream: frame_observer_failure_upstream(self(), kind))

      assert {:ok, stable_downstream} =
               WebsocketOwnerSession.attach_downstream(
                 owner,
                 downstream_target(correlation_id)
               )

      parent = self()

      submitter =
        Task.async(fn ->
          downstream = Map.put(stable_downstream, :owner_turn_id, self())

          request_options =
            fixture.session
            |> owner_request_options(fixture.lease_token, downstream, nil,
              payload: fixture.payload,
              request_id: fixture.accounting.request.correlation_id
            )
            |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)

          {prepared_context, request} =
            runtime_dispatch_fixture(
              upstream,
              auth,
              fixture.assignment,
              fixture.identity,
              fixture.model,
              request_options,
              fixture.accounting,
              fixture.payload
            )

          finalized_websocket_request(prepared_context, request, notify: parent)
        end)

      owner_turn_id = submitter.pid

      assert_receive {:websocket_owner_output_commit_probe, ^correlation_id, 1, ^owner_turn_id,
                      active_turn_ref, ^owner, probe_ref}

      assert Task.yield(submitter, 0) == nil

      send(
        owner,
        {:websocket_owner_output_commit_ack, correlation_id, 1, owner_turn_id, active_turn_ref,
         probe_ref, true}
      )

      assert_receive {:websocket_owner_frame, ^correlation_id, 1, ^owner_turn_id,
                      {:error, :upstream_stream_error, safe_payload}}

      assert safe_payload.code == "server_error"
      assert_receive {:websocket_owner_frame, ^correlation_id, 1, ^owner_turn_id, :complete}

      assert_receive {:websocket_owner_frame, ^correlation_id, 1, ^owner_turn_id,
                      {:data, ^expected_created}}

      assert_receive {:websocket_owner_frame, ^correlation_id, 1, ^owner_turn_id,
                      {:data, ^expected_visible}}

      assert_receive {:owner_frame_observer_called, ^kind, _owner_upstream_pid,
                      "response.created"}

      assert_receive {:owner_frame_observer_called, ^kind, _owner_upstream_pid,
                      "response.output_text.delta"}

      refute_received {:owner_frame_observer_called, ^kind, _owner_upstream_pid, _duplicate}

      assert {:error, %{code: "upstream_request_failed", status: 502}} =
               Task.await(submitter, @detection_timeout_ms)

      assert FakeUpstream.count(upstream) == 1
      refute_received {:websocket_owner_frame, ^correlation_id, 1, ^owner_turn_id, _duplicate}
      assert %{active_turn: nil} = :sys.get_state(owner)
      assert_failed_accounting!(fixture.accounting, "failed", "upstream_stream_error")
    end
  end

  test "v1 mapper and writer faults terminate the owner path", %{auth: auth} do
    for callback_kind <- [:mapper, :writer] do
      terminal = terminal_frame("resp_mandatory_#{callback_kind}")
      correlation_id = "corr-mandatory-#{callback_kind}"
      interruption_release_ref = make_ref()
      upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([terminal]))
      fixture = protocol_runtime_fixture(auth, callback_kind)

      {:ok, owner} =
        start_owner(fixture.session,
          upstream: mandatory_callback_failure_upstream(self(), callback_kind),
          persistence: callback_failure_persistence_boundary(self(), interruption_release_ref)
        )

      owner_ref = Process.monitor(owner)

      assert {:ok, downstream} =
               WebsocketOwnerSession.attach_downstream(
                 owner,
                 downstream_target(correlation_id)
               )

      request_options =
        owner_request_options(
          fixture.session,
          fixture.lease_token,
          downstream,
          nil,
          payload: fixture.payload,
          request_id: fixture.accounting.request.correlation_id
        )

      {prepared_context, request} =
        runtime_dispatch_fixture(
          upstream,
          auth,
          fixture.assignment,
          fixture.identity,
          fixture.model,
          request_options,
          fixture.accounting,
          fixture.payload
        )

      finalizer =
        Task.async(fn ->
          with_log(fn -> finalized_websocket_request(prepared_context, request, []) end)
        end)

      assert_receive {:callback_failure_interruption_ready, interruption_pid,
                      ^interruption_release_ref}

      assert {result, _log} = Task.await(finalizer, @detection_timeout_ms)

      assert {:error, %{code: "owner_crashed", status: 502}} = result
      assert_failed_accounting!(fixture.accounting, "failed", "owner_crashed")

      send(interruption_pid, {:release_callback_failure_interruption, interruption_release_ref})
      assert_receive {:callback_failure_interruption_complete, ^interruption_release_ref}
      assert_receive {:mandatory_callback_invoked, ^callback_kind}
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, @detection_timeout_ms
      assert FakeUpstream.count(upstream) == 1
      refute_received {:mandatory_callback_invoked, ^callback_kind}

      assert_receive {:websocket_owner_frame, ^correlation_id, 1,
                      {:error, :owner_crashed, safe_payload}}

      assert safe_payload.code == "owner_crashed"
      assert_receive {:websocket_owner_frame, ^correlation_id, 1, :complete}
      refute_received {:websocket_owner_frame, ^correlation_id, 1, _duplicate}
      assert_failed_accounting!(fixture.accounting, "failed", "owner_crashed")
    end
  end

  test "submission observer raise throw and exit run once without changing owner delivery", %{
    auth: auth
  } do
    parent = self()

    for {kind, observer} <- [
          raise: fn ->
            send(parent, {:submission_failure_observer_called, :raise, self()})
            raise "synthetic observer failure"
          end,
          throw: fn ->
            send(parent, {:submission_failure_observer_called, :throw, self()})
            throw(:synthetic_observer_failure)
          end,
          exit: fn ->
            send(parent, {:submission_failure_observer_called, :exit, self()})
            exit(:synthetic_observer_failure)
          end
        ] do
      identity = active_upstream_identity_fixture()
      terminal = terminal_frame("resp_observer_#{kind}")
      correlation_id = "corr-#{kind}"
      upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([terminal]))
      %{session: session, lease_token: lease_token} = owner_session_fixture(auth, kind)
      {:ok, owner} = start_owner(session)

      assert {:ok, downstream} =
               WebsocketOwnerSession.attach_downstream(owner, downstream_target(correlation_id))

      request_options =
        session
        |> owner_request_options(lease_token, downstream, nil)
        |> RequestOptions.put_transport(websocket_owner_submission_observer: observer)

      assert {:ok, %{terminal: "response.completed", status: 200}} =
               upstream
               |> dispatch_request(identity, request_options)
               |> websocket_request()

      assert_receive {:websocket_owner_frame, ^correlation_id, 1, {:data, ^terminal}}
      assert_receive {:websocket_owner_frame, ^correlation_id, 1, :complete}
      assert_receive {:submission_failure_observer_called, ^kind, observer_pid}
      assert observer_pid == self()
      refute_received {:submission_failure_observer_called, ^kind, _duplicate}
      refute_received {:websocket_owner_frame, ^correlation_id, 1, {:data, ^terminal}}
      refute_received {:websocket_owner_frame, ^correlation_id, 1, _duplicate}
      assert FakeUpstream.count(upstream) == 1
      assert Process.alive?(owner)
    end
  end

  test "owner-local frame observer raise throw and exit preserve writer delivery", %{auth: auth} do
    parent = self()

    for kind <- [:raise, :throw, :exit] do
      identity = active_upstream_identity_fixture()
      terminal = terminal_frame("resp_frame_observer_#{kind}")
      correlation_id = "corr-frame-observer-#{kind}"
      upstream = start_fake_upstream(FakeUpstream.websocket_text_frames([terminal]))
      %{session: session, lease_token: lease_token} = owner_session_fixture(auth, kind)

      {:ok, owner} =
        start_owner(session, upstream: frame_observer_failure_upstream(parent, kind))

      %{upstream_pid: owner_upstream_pid} = :sys.get_state(owner)

      assert {:ok, downstream} =
               WebsocketOwnerSession.attach_downstream(owner, downstream_target(correlation_id))

      request_options = owner_request_options(session, lease_token, downstream, nil)

      assert {:ok, %{terminal: "response.completed", status: 200}} =
               upstream
               |> dispatch_request(identity, request_options)
               |> websocket_request()

      assert_receive {:owner_frame_observer_called, ^kind, ^owner_upstream_pid,
                      "response.completed"}

      assert_receive {:websocket_owner_frame, ^correlation_id, 1, {:data, ^terminal}}
      assert_receive {:websocket_owner_frame, ^correlation_id, 1, :complete}
      refute_received {:owner_frame_observer_called, ^kind, _owner_upstream_pid, _duplicate}
      refute_received {:websocket_owner_frame, ^correlation_id, 1, _duplicate}
      assert FakeUpstream.count(upstream) == 1
      assert Process.alive?(owner)
      assert Process.alive?(owner_upstream_pid)
    end
  end

  defp mapper_cases do
    [
      {:public_openai_responses,
       &RequestOptions.put_openai_compatibility(&1, public_openai_responses_stream: true),
       &StreamProtocol.normalize_public_openai_responses_json_message/1},
      {:native_codex_responses, & &1,
       &StreamProtocol.canonicalize_native_codex_responses_json_message/1},
      {:codex_responses,
       &RequestOptions.put_openai_compatibility(&1,
         source_endpoint: "/v1/responses",
         public_openai_responses_stream: false
       ), &StreamProtocol.canonicalize_codex_responses_json_message/1}
    ]
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp accounting_turn_fixture(auth, session, assignment, model, mapper) do
    correlation_id = "protocol-accounting-#{mapper}-#{System.unique_integer([:positive])}"

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               model,
               %{"model" => model.exposed_model_id, "input" => "synthetic protocol turn"},
               %{
                 endpoint: "/backend-api/codex/responses",
                 transport: "websocket",
                 correlation_id: correlation_id,
                 request_metadata: %{"codex_session_id" => session.id}
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, assignment)
    assert {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    %{request: reserved.request, attempt: attempt, turn: turn}
  end

  defp protocol_runtime_fixture(auth, suffix, owner_instance_id \\ Atom.to_string(@remote_node)) do
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(auth.pool)

    model =
      model_fixture(auth.pool, %{
        exposed_model_id: "protocol-#{suffix}-#{System.unique_integer([:positive])}"
      })

    %{session: session, lease_token: lease_token} =
      owner_session_fixture(auth, suffix, owner_instance_id)

    accounting = accounting_turn_fixture(auth, session, assignment, model, suffix)
    payload = websocket_payload(model.exposed_model_id)

    %{
      accounting: accounting,
      assignment: assignment,
      identity: identity,
      lease_token: lease_token,
      model: model,
      payload: payload,
      session: session
    }
  end

  defp assert_successful_accounting!(accounting) do
    assert %Request{
             status: "succeeded",
             usage_status: "usage_known",
             response_status_code: 200,
             retry_count: 0,
             last_error_code: nil
           } = Repo.get!(Request, accounting.request.id)

    assert %Attempt{
             attempt_number: 1,
             status: "succeeded",
             usage_status: "usage_known",
             upstream_status_code: 200,
             retryable: false,
             network_error_code: nil
           } = Repo.get!(Attempt, accounting.attempt.id)

    assert %CodexTurn{
             status: "succeeded",
             final_attempt_id: attempt_id,
             error_code: nil
           } = Repo.get!(CodexTurn, accounting.turn.id)

    assert attempt_id == accounting.attempt.id

    assert [reservation, release, settlement] =
             Repo.all(
               from entry in LedgerEntry,
                 where: entry.request_id == ^accounting.request.id,
                 order_by: [asc: entry.occurred_at, asc: entry.entry_kind]
             )

    assert reservation.entry_kind == "reservation"
    assert reservation.attempt_id == nil
    assert release.entry_kind == "release"
    assert release.attempt_id == accounting.attempt.id
    assert release.usage_status == "usage_known"
    assert settlement.entry_kind == "settlement"
    assert settlement.attempt_id == accounting.attempt.id
    assert settlement.usage_status == "usage_known"
    assert settlement.input_tokens == 1
    assert settlement.output_tokens == 1
    assert settlement.total_tokens == 2

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id == ^accounting.request.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(turn in CodexTurn, where: turn.request_id == ^accounting.request.id),
             :count
           ) == 1
  end

  defp assert_failed_accounting!(accounting, turn_status, error_code) do
    response_status_code = failure_status_code(error_code)

    assert %Request{
             status: "failed",
             usage_status: "usage_unknown",
             response_status_code: ^response_status_code,
             retry_count: 0,
             last_error_code: ^error_code
           } = Repo.get!(Request, accounting.request.id)

    assert %Attempt{
             attempt_number: 1,
             status: "failed",
             usage_status: "usage_unknown",
             upstream_status_code: ^response_status_code,
             retryable: false,
             network_error_code: ^error_code
           } = Repo.get!(Attempt, accounting.attempt.id)

    assert %CodexTurn{
             status: ^turn_status,
             final_attempt_id: attempt_id,
             error_code: ^error_code
           } = Repo.get!(CodexTurn, accounting.turn.id)

    assert attempt_id == accounting.attempt.id

    assert [reservation, release, settlement] =
             Repo.all(
               from entry in LedgerEntry,
                 where: entry.request_id == ^accounting.request.id,
                 order_by: [asc: entry.occurred_at, asc: entry.entry_kind]
             )

    assert reservation.entry_kind == "reservation"
    assert reservation.attempt_id == nil
    assert release.entry_kind == "release"
    assert release.attempt_id == accounting.attempt.id
    assert release.usage_status == "usage_unknown"
    assert settlement.entry_kind == "settlement"
    assert settlement.attempt_id == accounting.attempt.id
    assert settlement.usage_status == "usage_unknown"

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id == ^accounting.request.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(turn in CodexTurn, where: turn.request_id == ^accounting.request.id),
             :count
           ) == 1
  end

  defp failure_status_code("client_disconnected"), do: 499
  defp failure_status_code("duplicate_downstream"), do: 409
  defp failure_status_code("owner_unavailable"), do: 503
  defp failure_status_code(_error_code), do: 502

  defp assert_replaced_owner_lease!(session, previous_lease_token) do
    assert %BridgeOwnerLease{
             status: "released",
             lease_token: ^previous_lease_token,
             metadata: %{"release_reason" => "owner_unavailable_takeover"}
           } = Repo.get_by!(BridgeOwnerLease, lease_token: previous_lease_token)

    assert [%BridgeOwnerLease{} = active] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^session.id and lease.status == "active"
             )

    assert active.lease_token != previous_lease_token
    assert active.metadata["source"] == "owner_unavailable_takeover"
    assert Repo.get!(CodexSession, session.id).owner_lease_token == active.lease_token

    assert Repo.aggregate(
             from(lease in BridgeOwnerLease, where: lease.codex_session_id == ^session.id),
             :count
           ) == 2
  end

  defp assert_unchanged_owner_lease!(session, lease_token) do
    assert [%BridgeOwnerLease{status: "active", lease_token: ^lease_token}] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^session.id
             )

    assert Repo.get!(CodexSession, session.id).owner_lease_token == lease_token
  end

  defp owner_session_fixture(auth, suffix, owner_instance_id \\ Atom.to_string(@remote_node)) do
    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "protocol-#{suffix}-#{System.unique_integer([:positive])}",
               owner_instance_id: owner_instance_id
             })

    session = Repo.get!(CodexSession, session.id)
    on_exit(fn -> cleanup_owner_session(session.id) end)
    %{session: session, lease_token: session.owner_lease_token}
  end

  defp start_owner(session, opts \\ []) do
    WebsocketOwnerSession.start_owner(
      Keyword.merge(
        [
          codex_session_id: session.id,
          owner_lease_token: session.owner_lease_token,
          owner_instance_id: session.owner_instance_id,
          owner_renewal_ms: 60_000
        ],
        opts
      )
    )
  end

  defp frame_observer_failure_upstream(parent, kind) do
    %{
      start: fn -> UpstreamWebsocketSession.start_link([]) end,
      send: fn upstream_pid, request, writer ->
        original_observer = request.frame_observer

        observer = fn frame, decoded ->
          send(parent, {:owner_frame_observer_called, kind, self(), decoded["type"]})
          invoke_frame_observer(original_observer, frame, decoded)
          fail_frame_observer(kind)
        end

        request = %{request | writer: writer, frame_observer: observer}
        UpstreamWebsocketSession.request(upstream_pid, request)
      end,
      close: &UpstreamWebsocketSession.close/1
    }
  end

  defp mandatory_callback_failure_upstream(parent, callback_kind) do
    %{
      start: fn -> UpstreamWebsocketSession.start_link([]) end,
      send: fn upstream_pid, request, owner_writer ->
        failing_callback = fn _frame ->
          send(parent, {:mandatory_callback_invoked, callback_kind})
          raise "synthetic mandatory callback failure"
        end

        request =
          case callback_kind do
            :mapper -> %{request | writer: owner_writer, message_mapper: failing_callback}
            :writer -> %{request | writer: failing_callback}
          end

        UpstreamWebsocketSession.request(upstream_pid, request)
      end,
      close: &UpstreamWebsocketSession.close/1
    }
  end

  defp callback_failure_persistence_boundary(parent, release_ref) do
    %{
      renew_owner_token: &SessionContinuity.renew_owner_token/3,
      release_owner_lease: &SessionContinuity.release_owner_lease/4,
      interrupt_codex_session: fn session_id, request_options ->
        send(parent, {:callback_failure_interruption_ready, self(), release_ref})

        receive do
          {:release_callback_failure_interruption, ^release_ref} -> :ok
        after
          @detection_timeout_ms -> raise "timed out waiting to release owner interruption"
        end

        result = Interruption.interrupt_codex_session(session_id, request_options)

        send(parent, {:callback_failure_interruption_complete, release_ref})
        result
      end
    }
  end

  defp terminal_result_barrier_upstream(parent, release_ref) do
    %{
      start: fn -> UpstreamWebsocketSession.start_link([]) end,
      send: fn upstream_pid, request, writer ->
        result = UpstreamWebsocketSession.request(upstream_pid, %{request | writer: writer})
        send(parent, {:terminal_result_barrier, self(), release_ref})

        receive do
          {:release_terminal_result, ^release_ref} -> result
        after
          @detection_timeout_ms -> raise "timed out waiting to release terminal result"
        end
      end,
      close: &UpstreamWebsocketSession.close/1
    }
  end

  defp invoke_frame_observer(observer, frame, decoded) when is_function(observer, 2),
    do: observer.(frame, decoded)

  defp invoke_frame_observer(observer, frame, _decoded) when is_function(observer, 1),
    do: observer.(frame)

  defp invoke_frame_observer(_observer, _frame, _decoded), do: :ok

  defp fail_frame_observer(:raise), do: raise("synthetic frame observer failure")
  defp fail_frame_observer(:throw), do: throw(:synthetic_frame_observer_failure)
  defp fail_frame_observer(:exit), do: exit(:synthetic_frame_observer_failure)

  defp owner_request_options(
         session,
         lease_token,
         downstream,
         reset_probe,
         opts \\ []
       ) do
    payload = Keyword.get(opts, :payload, websocket_payload("example-model"))

    RequestOptions.for_websocket(
      %{
        codex_session: session,
        receive_timeout_ms: 1_000,
        reset_probe: reset_probe,
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        client_request_id: Ecto.UUID.generate(),
        requested_model: payload["model"],
        effective_model: payload["model"],
        websocket_owner_forwarding_enabled?: true,
        websocket_owner_session: session,
        websocket_owner_lease_token: lease_token,
        websocket_owner_downstream: downstream,
        websocket_owner_downstream_epoch: downstream.epoch,
        websocket_owner_proxy_instance_id: Atom.to_string(node()),
        websocket_owner_instance_id: session.owner_instance_id,
        websocket_owner_forwarder_opts:
          Keyword.get(opts, :forwarder_opts, node_client: WebsocketOwnerNodeHarness)
      },
      payload
    )
  end

  defp websocket_request(request, opts \\ []) do
    WebsocketOwnerNodeHarness.with_node_client(
      [@remote_node],
      [
        calls: %{@remote_node => :success},
        capture_request_to: Keyword.get(opts, :capture_request_to),
        notify: Keyword.get(opts, :notify, self())
      ],
      fn _node_client_opts -> UpstreamDispatch.websocket_request(request) end
    )
  end

  defp dispatch_request(
         upstream,
         identity,
         request_options,
         accounting \\ nil,
         payload \\ websocket_payload("example-model")
       ) do
    %UpstreamDispatch.Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "synthetic-token",
      upstream_payload: Jason.encode!(Map.put(payload, "type", "response.create")),
      identity: identity,
      routing_hint_authorized?: true,
      accounting_request: accounting && accounting.request,
      accounting_attempt: accounting && accounting.attempt,
      writer: fn _message -> :ok end,
      assignment_advertised?: false,
      request_options: request_options,
      native_codex_response_control: nil
    }
  end

  defp runtime_dispatch_fixture(
         upstream,
         auth,
         assignment,
         identity,
         model,
         request_options,
         accounting,
         payload
       ) do
    context = %SelectedCandidateContext{
      auth: auth,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      model: model,
      reserved: %{request: accounting.request},
      request_options: request_options,
      route_plan:
        BridgeRing.plan_route(%{
          auth: auth,
          model: model,
          candidates: [{assignment, identity}],
          route_plan_input: RoutePlanInput.from_reserved(%{request: accounting.request}),
          request_options: request_options
        }),
      assignment: assignment,
      identity: identity,
      index: 0,
      retry_count: 0,
      allow_retry?: false,
      routing_attempt_metadata: %{},
      route_class: "proxy_websocket",
      attempt: accounting.attempt,
      started: System.monotonic_time(:millisecond)
    }

    prepared_context = %PreparedContext{
      context: context,
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "synthetic-token",
      upstream_payload: Jason.encode!(Map.put(payload, "type", "response.create")),
      routing_hint_authorized?: true
    }

    {prepared_context, dispatch_request(upstream, identity, request_options, accounting, payload)}
  end

  defp finalized_websocket_request(prepared_context, request, opts) do
    WebsocketOwnerNodeHarness.with_node_client(
      [@remote_node],
      [
        calls: %{@remote_node => :success},
        capture_request_to: Keyword.get(opts, :capture_request_to),
        notify: Keyword.get(opts, :notify, self())
      ],
      fn _node_client_opts ->
        WebsocketAttempt.dispatch(prepared_context, request, finalization_callbacks())
      end
    )
  end

  defp finalization_callbacks do
    %{
      register_continuity: fn _request_options, _payload, _body -> :ok end,
      stream_result: fn _response, _context -> :ok end
    }
  end

  defp websocket_payload(model) do
    %{"model" => model, "input" => "synthetic protocol turn", "stream" => true}
  end

  defp public_turn_downstream(downstream, :public_openai_responses),
    do: Map.put(downstream, :owner_turn_id, self())

  defp public_turn_downstream(downstream, _mapper), do: downstream

  defp downstream_target(correlation_id),
    do: %{pid: self(), correlation_id: correlation_id}

  defp owner_data_message(:public_openai_responses, downstream, owner_turn_id, payload),
    do:
      {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, owner_turn_id,
       {:data, payload}}

  defp owner_data_message(_mapper, downstream, _owner_turn_id, payload),
    do: {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, {:data, payload}}

  defp owner_complete_message(:public_openai_responses, downstream, owner_turn_id),
    do:
      {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, owner_turn_id,
       :complete}

  defp owner_complete_message(_mapper, downstream, _owner_turn_id),
    do: {:websocket_owner_frame, downstream.correlation_id, downstream.epoch, :complete}

  defp terminal_frame(response_id) do
    Jason.encode!(%{
      "type" => "response.completed",
      "response" => %{
        "id" => response_id,
        "status" => "completed",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      }
    })
  end

  defp output_delta_frame do
    Jason.encode!(%{
      "type" => "response.output_text.delta",
      "response_id" => "resp_visible_output",
      "output_index" => 0,
      "content_index" => 0,
      "delta" => "visible",
      "sequence_number" => 1
    })
  end

  defp response_created_frame do
    Jason.encode!(%{
      "type" => "response.created",
      "response" => %{"id" => "resp_visible_output", "status" => "in_progress"}
    })
  end

  defp terminal_barrier_downstream_sender(:public_openai_responses, terminal, release_ref) do
    test_pid = self()

    fn downstream_pid, message ->
      case message do
        {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, {:data, ^terminal}} ->
          send(
            test_pid,
            {:websocket_owner_harness_terminal_delivery_barrier, self(), release_ref}
          )

          receive do
            {:websocket_owner_harness_release_terminal_delivery, ^release_ref} -> :ok
          after
            @detection_timeout_ms ->
              raise "timed out waiting for public owner terminal delivery release"
          end

          send(downstream_pid, message)
          send(test_pid, {:websocket_owner_harness_terminal_delivered, release_ref})
          :ok

        _other ->
          send(downstream_pid, message)
          :ok
      end
    end
  end

  defp terminal_barrier_downstream_sender(_mapper, terminal, release_ref) do
    WebsocketOwnerNodeHarness.terminal_barrier_downstream_sender(
      self(),
      terminal,
      release_ref
    )
  end

  defp rate_limit_event(reset_at) do
    %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => 42,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }
  end

  defp bound_reset_probe(assignment, identity, effective_model) do
    assert {:ok, probe} =
             ResetProbe.bind(
               ResetProbe.new(),
               assignment.id,
               identity.id,
               effective_model,
               "proxy_websocket"
             )

    probe
  end

  defp mismatch_reset_probe_scope(probe, :assignment),
    do: %{probe | pool_upstream_assignment_id: Ecto.UUID.generate()}

  defp mismatch_reset_probe_scope(probe, :identity),
    do: %{probe | upstream_identity_id: Ecto.UUID.generate()}

  defp mismatch_reset_probe_scope(probe, :model),
    do: %{probe | effective_model: "mismatched-model"}

  defp mismatch_reset_probe_scope(probe, :route_class),
    do: %{probe | route_class: "proxy_stream"}

  defp attach_product_observer! do
    handler_id = "owner-protocol-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :multi_agent_round, :product_stage],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:product_observation, metadata})
        end,
        nil
      )

    handler_id
  end

  defp assert_product_observations do
    assert_receive {:product_observation,
                    %{direction: :provider_to_pooler, event_type: "response.completed"}}

    refute_received {:product_observation, %{event_type: "response.completed"}}
  end

  defp assert_quota_observation(identity, reset_at) do
    assert [window] = quota_observations(identity)

    assert Decimal.equal?(window.used_percent, Decimal.new("42.0"))
    assert DateTime.compare(window.reset_at, reset_at) == :eq
  end

  defp attach_quota_commit_barrier!(identity_id) do
    parent = self()
    handler_id = {__MODULE__, :quota_commit, System.unique_integer([:positive])}
    dumped_identity_id = Ecto.UUID.dump!(identity_id)

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:codex_pooler, :repo, :query],
               fn _event, _measurements, metadata, _config ->
                 maybe_hold_quota_write(
                   metadata,
                   handler_id,
                   parent,
                   identity_id,
                   dumped_identity_id
                 )
               end,
               nil
             )

    handler_id
  end

  defp maybe_hold_quota_write(metadata, handler_id, parent, identity_id, dumped_identity_id) do
    if metadata[:repo] == Repo do
      send(
        parent,
        {handler_id, self(), metadata[:source], metadata[:query] || "", metadata[:params] || []}
      )

      maybe_pause_quota_write(metadata, handler_id, parent, identity_id, dumped_identity_id)
    end
  end

  defp maybe_pause_quota_write(metadata, handler_id, parent, identity_id, dumped_identity_id) do
    if quota_window_insert?(metadata, identity_id, dumped_identity_id) do
      send(parent, {handler_id, :quota_write_ready, self()})

      receive do
        {^handler_id, :release_quota_write} -> :ok
      after
        5_000 -> raise "timed out waiting to release quota persistence"
      end
    end
  end

  defp quota_window_insert?(metadata, identity_id, dumped_identity_id) do
    metadata[:source] == "account_quota_windows" and insert_query?(metadata[:query]) and
      identity_parameter?(metadata[:params], identity_id, dumped_identity_id)
  end

  defp insert_query?(query) when is_binary(query),
    do: String.starts_with?(String.upcase(String.trim_leading(query)), "INSERT")

  defp insert_query?(_query), do: false

  defp identity_parameter?(params, identity_id, dumped_identity_id) when is_list(params),
    do: Enum.any?(params, &(&1 in [identity_id, dumped_identity_id]))

  defp identity_parameter?(_params, _identity_id, _dumped_identity_id), do: false

  defp await_quota_commit!(handler_id) do
    assert_receive {^handler_id, :quota_write_ready, task_pid}
    task_ref = Process.monitor(task_pid)
    send(task_pid, {handler_id, :release_quota_write})
    await_quota_commit_query!(handler_id, task_pid)
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}
  end

  defp await_quota_commit_query!(handler_id, task_pid) do
    receive do
      {^handler_id, ^task_pid, _source, query, _params} ->
        if String.upcase(String.trim(query)) == "COMMIT" do
          :ok
        else
          await_quota_commit_query!(handler_id, task_pid)
        end

      {^handler_id, _other_pid, _source, _query, _params} ->
        await_quota_commit_query!(handler_id, task_pid)
    after
      @detection_timeout_ms -> flunk("expected owner-local quota persistence commit")
    end
  end

  defp quota_observations(identity) do
    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.filter(&(&1.source == "codex_rate_limit_event" and &1.window_kind == "primary"))
  end

  defp start_fake_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp restore_observation_setting(nil),
    do: Application.delete_env(:codex_pooler, :multi_agent_round_product_observation_enabled)

  defp restore_observation_setting(value),
    do: Application.put_env(:codex_pooler, :multi_agent_round_product_observation_enabled, value)

  defp cleanup_owner_session(codex_session_id) do
    case Registry.lookup(WebsocketOwnerSession.Registry, codex_session_id) do
      [] ->
        :ok

      [{owner_pid, _value}] ->
        owner_ref = Process.monitor(owner_pid)
        :ok = GenServer.stop(owner_pid, :normal, 1_000)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner_pid, _reason} -> :ok
        after
          @detection_timeout_ms ->
            raise "timed out cleaning up test-owned websocket owner session"
        end

      owners ->
        raise "expected at most one test-owned websocket owner, got: #{length(owners)}"
    end
  end
end
