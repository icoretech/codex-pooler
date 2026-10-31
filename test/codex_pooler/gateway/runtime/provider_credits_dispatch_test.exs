defmodule CodexPooler.Gateway.Runtime.ProviderCreditsDispatchTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query

  alias CodexPooler.{Access, Accounting, FakeUpstream, ProviderCreditsFixtures, Repo, UnboxedFixture}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.SideEffects
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.ProviderCreditsAdmission
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.Websocket.{UpstreamWebsocketSession, WebsocketOwnerForwarder, WebsocketOwnerSession}
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.ProviderCreditsDispatchSupport
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.TestAppEnv
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.{AccountAvailabilityStore, CapacityFactsStore, Windows}
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets.{Convergence, ProbeLease, RedemptionLifecycle}
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport, as: SocketSupport
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, as: WireSupport
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence
  alias Ecto.Adapters.SQL.Sandbox

  @budget 15_000
  @endpoint "/backend-api/codex/responses"
  setup do
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
    :ok
  end

  @moduletag capture_log: true

  # A comprehension expands and compiles a test's body once per generated test, so a loop that generates more than a few tests keeps
  # the scenario in a private function below it and each generated test is one call.
  for mode <- [:full, :lite], mutation <- [:none, :binding_removed, :binding_epoch, :binding_model, :credential_epoch, :capacity] do
    @tag content_filter_boundary: true
    test "content-filter successor #{mode} checks #{mutation} on the actual remote owner before send" do
      assert_content_filter_successor_checks_mutation!(unquote(mode), unquote(mutation))
    end
  end

  defp assert_content_filter_successor_checks_mutation!(mode, mutation) do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :legacy_windowless)
    configure_runtime_mode!(setup, mode)
    client = open_owned_socket!(fixture, setup)
    metadata = native_metadata()
    original = native_payload(setup, metadata, SocketSupport.native_text_input("synthetic content filter"))
    original = if mode == :lite, do: put_in(original, ["client_metadata", "ws_request_header_x_openai_internal_codex_responses_lite"], "true"), else: original
    terminal = %{"type" => "response.incomplete", "response" => %{"id" => "resp_synthetic_filter", "status" => "incomplete", "incomplete_details" => %{"reason" => "content_filter"}, "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}
    FakeUpstream.set_mode(fixture.upstream, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(terminal)]))
    {client, first} = send_socket_turn!(client, original)
    assert first["type"] == "response.incomplete"
    assert generation_count(fixture) == 1
    guidance = %{"type" => "message", "role" => "developer", "content" => [%{"type" => "input_text", "text" => "<content_filter_guidance>\nsynthetic guidance\n</content_filter_guidance>"}]}
    successor = Map.update!(original, "input", &(&1 ++ [guidance]))
    FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_filter_successor", []))
    selected = hold_socket_generation!(client, successor)
    assert selected.summary.request_id != nil
    assert selected.summary.attempt_id != nil

    UnboxedFixture.run_unboxed(fn ->
      request = Repo.get!(Accounting.Request, selected.summary.request_id)
      assert request.request_metadata["native_content_filter_binding"]["version"] == 1

      case mutation do
        :binding_removed ->
          request |> Ecto.Changeset.change(request_metadata: Map.delete(request.request_metadata, "native_content_filter_binding")) |> Repo.update!()

        :binding_epoch ->
          request |> Ecto.Changeset.change(request_metadata: put_in(request.request_metadata, ["native_content_filter_binding", "credential_epoch"], 2)) |> Repo.update!()

        :binding_model ->
          request |> Ecto.Changeset.change(request_metadata: put_in(request.request_metadata, ["native_content_filter_binding", "upstream_model"], "synthetic-changed-model")) |> Repo.update!()

        :credential_epoch ->
          identity = Repo.get!(UpstreamIdentity, setup.identity.id)
          identity |> Ecto.Changeset.change(metadata: CredentialFencing.advance_credential_epoch(identity)) |> Repo.update!()

        _other ->
          :ok
      end
    end)

    if mutation == :capacity, do: ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, false, fixture.peer.node)
    send(selected.sender, {:provider_credits_owner_release, selected.reference})
    {client, final} = receive_client_terminal(selected.client)

    if mutation == :none do
      assert final["type"] == "response.completed"
      assert generation_count(fixture) == 2
    else
      assert final["type"] in ["error", "response.failed"]
      assert generation_count(fixture) == 1
      assert_unsent_attempt!(selected.summary.attempt_id)
    end

    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    close_client!(client)
  end

  for mode <- [:full, :lite], transport <- [:http_json, :http_sse, :native_websocket, :bridged_websocket] do
    test "included capacity remains physically admitted with opt-out over #{transport} #{mode}" do
      assert_included_capacity_admitted_with_opt_out!(unquote(transport), unquote(mode))
    end

    test "fresh credit-only permission physically sends in both Pools over #{transport} #{mode}" do
      assert_fresh_credit_only_permission_sends_in_both_pools!(unquote(transport), unquote(mode))
    end

    @tag credits_negative: true
    test "credit opt-out is final for actual credit-only capacity over #{transport} #{mode}" do
      assert_credit_opt_out_final_for_credit_only_capacity!(unquote(transport), unquote(mode))
    end

    @tag credits_negative: true
    test "workspace denial blocks a selected included identity over #{transport} #{mode}" do
      assert_workspace_denial_blocks_included_identity!(unquote(transport), unquote(mode))
    end

    @tag credits_negative: true
    test "late workspace header below exhaustion denies every admitted basis over #{transport} #{mode}" do
      assert_late_workspace_header_denies_every_basis!(unquote(transport), unquote(mode))
    end

    @tag reset_recovery_dispatch: true
    test "authorized consume and matching included confirmation precede #{transport} #{mode} generation" do
      assert_consume_and_included_confirmation_precede_generation!(unquote(transport), unquote(mode))
    end
  end

  defp assert_included_capacity_admitted_with_opt_out!(transport, mode) do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :included)
    request = request(fixture, setup, transport, mode)
    assert {:ok, result} = execute(request, nil)
    receipt = admission(result)
    assert receipt.capacity_basis in [:included_window, :ordinary_provider_permission]
    refute receipt.non_credit_guarded_probe

    if transport == :http_sse do
      assert %Req.Response.Async{} = result.body
      assert drain_http(result) =~ "response.completed"
    end

    assert receipt.context.serving_mode == mode
    assert receipt.context.transport == transport
    assert generation_count(fixture) == 1
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  defp assert_fresh_credit_only_permission_sends_in_both_pools!(transport, mode) do
    fixture = open!(allow_provider_credits: true)

    for pool <- [:a, :b], state <- [:weekly_credit_only, :windowless_credit_only] do
      setup = ProviderCreditsFixtures.runtime_setup!(fixture, pool, state, model: "synthetic-#{state}-#{pool}")
      request = request(fixture, setup, transport, mode)
      assert {:ok, response} = execute(request, nil)
      assert admission(response).capacity_basis == :provider_credits
      refute admission(response).non_credit_guarded_probe
      assert admission(response).context.upstream_model == setup.model.upstream_model_id
      if transport == :http_sse, do: assert(drain_http(response) =~ "response.completed")
    end

    assert generation_count(fixture) == 4
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  defp assert_credit_opt_out_final_for_credit_only_capacity!(transport, mode) do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :windowless_credit_only)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false, reason_codes: reasons}} = execute(request(fixture, setup, transport, mode), nil)
    assert "provider_credits_disabled" in reasons
    assert generation_count(fixture) == 0
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  defp assert_workspace_denial_blocks_included_identity!(transport, mode) do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :included)
    selected = request(fixture, setup, transport, mode)

    UnboxedFixture.run_unboxed(fn ->
      ProviderCreditsFixtures.persist_usage!(Repo.get!(UpstreamIdentity, setup.identity.id), ProviderCreditsFixtures.usage_payload(:workspace_blocked), DateTime.utc_now())
    end)

    assert {:error, %{reason: :provider_credits_policy_denied, started: false, reason_codes: reasons}} = execute(selected, nil)
    assert "provider_denied" in reasons
    assert generation_count(fixture) == 0
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  defp assert_late_workspace_header_denies_every_basis!(transport, mode) do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :included)
    selected = request(fixture, setup, transport, mode)
    denied_at = persist_runtime_denial!(setup.identity)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false, reason_codes: reasons, candidate_exclusions: [exclusion]}} = execute(selected, nil)
    assert reasons == ["exhausted", "provider_denied"]
    assert [%{"rate_limit_reached_type" => "workspace_member_credits_depleted", "quota_scope" => "account"}] = Enum.map(exclusion.reasons, &Map.take(&1, ["rate_limit_reached_type", "quota_scope"]))
    assert generation_count(fixture) == 0

    UnboxedFixture.run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, setup.identity.id)
      epoch = CredentialFencing.credential_epoch(identity)
      metadata = Map.put(identity.metadata, AccountAvailabilityStore.metadata_key(), AccountAvailabilityStore.encode!(:available, DateTime.add(denied_at, 1, :microsecond), epoch))
      Repo.update!(Ecto.Changeset.change(identity, metadata: metadata))
    end)

    assert {:ok, result} = execute(selected, nil)
    assert admission(result).capacity_basis in [:included_window, :ordinary_provider_permission]
    if transport == :http_sse, do: assert(drain_http(result) =~ "response.completed")
    assert generation_count(fixture) == 1
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  defp assert_consume_and_included_confirmation_precede_generation!(transport, mode) do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :weekly_credit_only)

    old_event =
      UnboxedFixture.run_unboxed(fn ->
        old = Enum.find(Windows.list_evidence(setup.identity), &(&1.source == "codex_usage_api" and &1.window_minutes == 10_080))
        observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        attrs = old |> Map.from_struct() |> Map.take([:quota_key, :quota_scope, :quota_family, :window_kind, :window_minutes, :used_percent, :reset_at, :source_precision, :freshness_state, :metadata]) |> Map.merge(%{source: "codex_rate_limit_event", observed_at: observed_at, last_sync_at: observed_at})
        assert {:ok, [event]} = Windows.upsert_quota_windows(setup.identity, [attrs], delete_missing?: false)
        assert Decimal.equal?(event.used_percent, 100)
        event
      end)

    recovered = recover_included!(fixture, setup, reset_after: 10_800)
    redemption = recovered.metadata["saved_reset_redemption"]
    assert redemption["phase"] == "confirmed_by_quota"
    {:ok, consumed_at, _offset} = DateTime.from_iso8601(redemption["consumed_at"])
    assert DateTime.compare(old_event.observed_at, consumed_at) == :lt

    UnboxedFixture.run_unboxed(fn ->
      as_of = DateTime.utc_now()
      windows = Windows.list_evidence(recovered)
      assert Enum.find(windows, &(&1.id == old_event.id)) == old_event
      assert DateTime.diff(as_of, old_event.observed_at, :second) < Evidence.freshness_ttl_seconds()
      assert Evidence.current_freshness_state(old_event, as_of) == "fresh"
      usage = Enum.find(windows, &(&1.source == "codex_usage_api" and &1.window_minutes == 10_080))
      assert Decimal.compare(usage.used_percent, Decimal.new(100)) == :lt
      assert DateTime.compare(usage.observed_at, consumed_at) != :lt
      assert DateTime.diff(usage.reset_at, old_event.reset_at, :second) > 5
    end)

    request = request(fixture, %{setup | identity: recovered}, transport, mode)
    assert {:ok, result} = execute(request, nil)
    assert admission(result).capacity_basis == :recovered_included
    refute admission(result).non_credit_guarded_probe
    if transport == :http_sse, do: assert(drain_http(result) =~ "response.completed")
    assert generation_count(fixture) == 1
    receipts = FakeUpstream.physical_receipts(fixture.upstream)
    assert [consume] = Enum.filter(receipts, &(&1.kind == :consume))
    assert [generation] = Enum.filter(receipts, &(&1.kind == :generation))
    assert confirmation = Enum.find(receipts, &(&1.kind == :usage and &1.ordinal > consume.ordinal))
    assert consume.ordinal < confirmation.ordinal
    assert confirmation.ordinal < generation.ordinal
  end

  for mode <- [:full, :lite], transport <- [:http_json, :http_sse] do
    @tag credits_negative: true
    test "T3 #{transport} final read observes the other replica's revocation in both Pools #{mode}" do
      assert_final_read_observes_other_replica_revocation!(unquote(transport), unquote(mode))
    end

    test "T4 #{transport} admitted read may finish after opt-out and the next Pool rechecks #{mode}" do
      assert_admitted_read_may_finish_after_opt_out!(unquote(transport), unquote(mode))
    end
  end

  defp assert_final_read_observes_other_replica_revocation!(transport, mode) do
    fixture = open!(allow_provider_credits: true)

    for pool <- [:a, :b] do
      ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, true)
      setup = ProviderCreditsFixtures.runtime_setup!(fixture, pool, :legacy_windowless)
      request = request(fixture, setup, transport, mode)
      reference = make_ref()
      worker = ProviderCreditsFixtures.start_peer_work!(fixture, {ProviderCreditsDispatchSupport, :held_http, [request, self(), reference]})
      assert_receive {:dispatch_reader_ready, ^reference, reader, backend}, @budget
      barrier = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, backend_pid: backend)
      send(reader, {:dispatch_read, reference})
      assert %{phase: :before_final_read, backend_pid: ^backend} = ProviderCreditsFixtures.await_before_read!(barrier)
      ProviderCreditsFixtures.commit_policy_and_release!(barrier, false)
      assert {:error, %{reason: :provider_credits_policy_denied, started: false, reason_codes: reasons}} = await_worker(worker)
      assert "provider_credits_disabled" in reasons
      assert generation_count(fixture) == 0
    end
  end

  defp assert_admitted_read_may_finish_after_opt_out!(transport, mode) do
    fixture = open!(allow_provider_credits: true)
    first = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :legacy_windowless)
    second = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :legacy_windowless)
    barrier = ProviderCreditsFixtures.after_read_barrier!(fixture, first.identity.id, node: fixture.peer.node)
    worker = ProviderCreditsFixtures.start_peer_work!(fixture, {ProviderCreditsDispatchSupport, :execute_terminal, [request(fixture, first, transport, mode), nil]})
    reference = barrier.ref
    assert_receive {:provider_credits_barrier, ^reference, :after_final_read, emitter}, @budget
    assert emitter == worker.pid
    assert generation_count(fixture) == 0
    ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, false)
    ProviderCreditsFixtures.release_barrier!(barrier)
    assert {:ok, response} = await_worker(worker)
    assert admission(response).capacity_basis == :unknown_legacy
    if transport == :http_sse, do: assert(response.terminal_completed?)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request(fixture, second, transport, mode), nil)
    assert generation_count(fixture) == 1
  end

  for mode <- [:full, :lite] do
    @tag credits_negative: true
    test "T3 T4 reused direct Mint connection rechecks every queued generation #{mode}" do
      fixture = open!(allow_provider_credits: true)
      setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :legacy_windowless)
      {:ok, session} = :erpc.call(fixture.peer.node, ProviderCreditsDispatchSupport, :start_session, [], @budget)
      request = request(fixture, setup, :native_websocket, unquote(mode))
      assert {:ok, warmup} = :erpc.call(fixture.peer.node, ProviderCreditsDispatchSupport, :execute, [request, session], @budget)
      lifecycle = warmup.upstream_websocket_connection.lifecycle_id
      assert generation_count(fixture) == 1
      barrier = ProviderCreditsFixtures.after_read_barrier!(fixture, setup.identity.id, node: fixture.peer.node, emitter: session)
      worker = ProviderCreditsFixtures.start_peer_work!(fixture, {ProviderCreditsDispatchSupport, :execute, [request, session]})
      reference = barrier.ref
      assert_receive {:provider_credits_barrier, ^reference, :after_final_read, ^session}, @budget
      ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, false)
      ProviderCreditsFixtures.release_barrier!(barrier)
      assert {:ok, admitted} = await_worker(worker)
      assert admitted.upstream_websocket_connection.reused
      assert admitted.upstream_websocket_connection.lifecycle_id == lifecycle
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = :erpc.call(fixture.peer.node, ProviderCreditsDispatchSupport, :execute, [request, session], @budget)
      assert generation_count(fixture) == 2
      assert {:ok, %{lifecycle_id: ^lifecycle}} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [session], @budget)
      ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, true)
      before = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, read_relation: :account_quota_windows, query_predicate: &final_read_query?/1)
      denied_worker = ProviderCreditsFixtures.start_peer_work!(fixture, {ProviderCreditsDispatchSupport, :execute, [request, session]})
      assert %{phase: :before_final_read} = ProviderCreditsFixtures.await_before_read!(before)
      ProviderCreditsFixtures.commit_policy_and_release!(before, false)
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = await_worker(denied_worker)
      assert generation_count(fixture) == 2
      :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :close, [session], @budget)
    end

    @tag credits_negative: true
    test "T3 T4 real remote owner v8 retains its connection across cross-node opt-out #{mode}" do
      fixture = open!(allow_provider_credits: true)
      setup = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :legacy_windowless)
      {request, owner, upstream_session} = owned_request(fixture, setup, unquote(mode))
      assert node(owner) == fixture.peer.node
      assert {:ok, warmup} = execute(request, nil)
      lifecycle = warmup.upstream_websocket_connection.lifecycle_id
      barrier = ProviderCreditsFixtures.after_read_barrier!(fixture, setup.identity.id, node: fixture.peer.node, emitter: upstream_session)
      task = Task.async(fn -> execute(request, nil) end)
      reference = barrier.ref
      assert_receive {:provider_credits_barrier, ^reference, :after_final_read, ^upstream_session}, @budget
      ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, false)
      ProviderCreditsFixtures.release_barrier!(barrier)
      assert {:ok, admitted} = Task.await(task, @budget)
      assert admission(admitted).capacity_basis == :unknown_legacy
      assert admitted.upstream_websocket_connection.reused
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request, nil)
      assert generation_count(fixture) == 2
      ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, true)
      before = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, read_relation: :account_quota_windows, query_predicate: &final_read_query?/1)
      denied_task = Task.async(fn -> execute(request, nil) end)
      assert %{phase: :before_final_read} = ProviderCreditsFixtures.await_before_read!(before)
      ProviderCreditsFixtures.commit_policy_and_release!(before, false)
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = Task.await(denied_task, @budget)
      assert generation_count(fixture) == 2
      assert {:ok, %{lifecycle_id: ^lifecycle}} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [upstream_session], @budget)
    end
  end

  for path <- ["/backend-api/codex/responses", "/v1/responses"], mode <- ["full", "lite"], state <- [:included, :weekly_credit_only] do
    @tag credits_negative: true
    test "native public boundary #{path} #{mode} admits actual #{state} permission" do
      assert_public_boundary_admits_actual_permission!(unquote(state), unquote(mode), unquote(path))
    end
  end

  defp assert_public_boundary_admits_actual_permission!(state, mode, path) do
    TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    fixture = open!(allow_provider_credits: state == :weekly_credit_only)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, state)
    FakeUpstream.set_mode(fixture.upstream, FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_surface", "status" => "completed", "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}})]))

    UnboxedFixture.run_unboxed(fn ->
      now = DateTime.utc_now()
      Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: now, updated_at: now})
    end)

    {_server, port} = SocketSupport.start_public_endpoint_with_server!()
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, reference} = SocketSupport.public_websocket_connect!(port, setup, Ecto.UUID.generate(), path)
    socket = Mint.HTTP.get_socket(conn)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket_pid = WebsocketCleanupFence.await_new_listener_socket!(before)
    frame = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic"}]}], "stream" => true})
    {conn, websocket} = SocketSupport.public_websocket_send_text!(conn, websocket, reference, frame)
    {conn, _websocket, terminal} = receive_terminal(conn, websocket, reference)

    assert terminal["type"] == "response.completed"
    assert generation_count(fixture) == 1

    Mint.HTTP.close(conn)
    WebsocketCleanupFence.await_listener_socket_teardown!(socket_pid)
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  for path <- ["/backend-api/codex/responses", "/v1/responses"], mode <- [:full, :lite], boundary <- [:credit_off, :workspace, :recovered] do
    @tag credits_negative: true
    test "public Socket #{path} #{mode} enforces #{boundary} at its actual wire boundary" do
      assert_public_socket_enforces_boundary_at_wire!(unquote(boundary), unquote(mode), unquote(path))
    end
  end

  defp assert_public_socket_enforces_boundary_at_wire!(boundary, mode, path) do
    fixture = open!(allow_provider_credits: boundary != :credit_off)
    state = if boundary == :workspace, do: :included, else: :weekly_credit_only
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, state)
    configure_runtime_mode!(setup, mode)

    case boundary do
      :recovered -> recover_included!(fixture, setup)
      :workspace -> persist_runtime_denial!(setup.identity)
      :credit_off -> :ok
    end

    FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_public_matrix", []))
    {_server, port} = SocketSupport.start_public_endpoint_with_server!()
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, reference} = SocketSupport.public_websocket_connect!(port, setup, Ecto.UUID.generate(), path)
    socket = Mint.HTTP.get_socket(conn)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket_pid = WebsocketCleanupFence.await_new_listener_socket!(before)
    payload = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => SocketSupport.native_text_input("synthetic public matrix"), "stream" => true}
    {conn, websocket} = SocketSupport.public_websocket_send_text!(conn, websocket, reference, CodexPooler.JSON.encode!(payload))
    {conn, _websocket, terminal} = receive_terminal(conn, websocket, reference)
    WireSupport.await_socket_connection_state!(socket_pid, &(MapSet.size(&1.tasks) == 0))

    if boundary == :recovered do
      assert terminal["type"] == "response.completed"
      assert generation_count(fixture) == 1
      receipts = FakeUpstream.physical_receipts(fixture.upstream)
      assert [consume] = Enum.filter(receipts, &(&1.kind == :consume))
      assert [generation] = Enum.filter(receipts, &(&1.kind == :generation))
      assert confirmation = Enum.find(receipts, &(&1.kind == :usage and &1.ordinal > consume.ordinal))
      assert consume.ordinal < confirmation.ordinal and confirmation.ordinal < generation.ordinal
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 1
    else
      assert terminal["type"] in ["error", "response.failed"]
      assert generation_count(fixture) == 0
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    end

    Mint.HTTP.close(conn)
    WebsocketCleanupFence.await_listener_socket_teardown!(socket_pid)
  end

  for mode <- [:full, :lite], operation <- [:anchored, :steer, :compact] do
    @tag credits_negative: true
    test "T3 actual remote Socket #{operation} generation honors final-read revocation #{mode}" do
      assert_remote_socket_generation_honors_final_read_revocation!(unquote(mode), unquote(operation))
    end
  end

  defp assert_remote_socket_generation_honors_final_read_revocation!(mode, operation) do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :legacy_windowless)
    metadata = native_metadata()
    configure_runtime_mode!(setup, mode)
    client = open_owned_socket!(fixture, setup)
    output = synthetic_assistant_item("msg_synthetic_gate_anchor")
    anchor = "resp_synthetic_gate_anchor"
    FakeUpstream.set_mode(fixture.upstream, native_completed(anchor, [output]))
    {client, terminal} = send_socket_turn!(client, native_payload(setup, metadata, SocketSupport.native_text_input("synthetic opener")))
    assert terminal["type"] == "response.completed"
    assert generation_count(fixture) == 1
    assert {:ok, connection} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [client.upstream_session], @budget)
    lifecycle = connection.lifecycle_id
    assert_active_anchor!(client.codex_session_id, anchor)

    FakeUpstream.set_mode(fixture.upstream, generation_reply(operation, "resp_synthetic_gate_positive"))
    payload = controlled_generation_payload(setup, metadata, operation, anchor)
    positive = hold_socket_generation!(client, payload)
    assert_handoff_contract!(positive.summary, operation, mode)
    send(positive.sender, {:provider_credits_owner_release, positive.reference})
    {client, positive_terminal} = receive_client_terminal(positive.client)
    assert positive_terminal["type"] == "response.completed"
    assert generation_count(fixture) == 2
    {client, admitted_count} = complete_positive_control!(client, fixture, setup, metadata, operation, positive_terminal)

    metadata = native_metadata()
    FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_gate_retained", [output]))
    {client, opener} = send_socket_turn!(client, native_payload(setup, metadata, SocketSupport.native_text_input("synthetic second opener")))
    retained = opener["response"]["id"]
    assert generation_count(fixture) == admitted_count + 1
    assert_active_anchor!(client.codex_session_id, retained)
    selected = hold_socket_generation!(client, controlled_generation_payload(setup, metadata, operation, retained))
    assert_handoff_contract!(selected.summary, operation, mode)
    before = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, read_relation: :account_quota_windows, query_predicate: &final_read_query?/1)
    send(selected.sender, {:provider_credits_owner_release, selected.reference})
    assert %{phase: :before_final_read} = ProviderCreditsFixtures.await_before_read!(before)
    ProviderCreditsFixtures.commit_policy_and_release!(before, false)
    {client, denied} = receive_client_terminal(selected.client)
    assert denied["type"] in ["error", "response.failed"]
    assert generation_count(fixture) == admitted_count + 1
    assert_active_anchor!(client.codex_session_id, retained)
    assert {:ok, %{lifecycle_id: ^lifecycle}} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [client.upstream_session], @budget)
    assert_unsent_attempt!(selected.summary.attempt_id)
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    close_client!(client)
  end

  for mode <- [:full, :lite], revoke? <- [false, true] do
    @tag credits_negative: true
    test "T3 real Socket suspended replay uses its actual capability and final read #{mode} revoke=#{revoke?}" do
      assert_suspended_socket_replay_uses_actual_capability!(unquote(mode), unquote(revoke?))
    end
  end

  defp assert_suspended_socket_replay_uses_actual_capability!(mode, revoke?) do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :legacy_windowless)
    configure_runtime_mode!(setup, mode)
    client = open_owned_socket!(fixture, setup)
    release_ref = make_ref()
    FakeUpstream.set_mode(fixture.upstream, FakeUpstream.websocket_close_without_terminal_barrier(notify: self(), release_ref: release_ref, code: 1001, reason: "synthetic replay cut"))
    payload = native_payload(setup, native_metadata(), [%{"type" => "function_call_output", "call_id" => "call_synthetic_replay", "output" => "synthetic"}])
    client = send_client_frame(client, payload)
    assert_receive {:fake_upstream_websocket_barrier, :before_close, handler, ^release_ref}, @budget
    assert :erpc.call(fixture.peer.node, :sys, :get_state, [client.owner], @budget).active_turn.descriptor.replay_generation == 0
    close_client!(client)
    assert :erpc.call(fixture.peer.node, :sys, :get_state, [client.owner], @budget).suspended_replay.provisional_status == :armed
    send(handler, {:fake_upstream_release_websocket, release_ref})
    assert generation_count(fixture) == 1
    client = reconnect_owned_socket!(fixture, setup, client)
    FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_replay_positive", []))
    selected = hold_socket_generation!(client, payload)
    assert selected.summary.native_replay?
    assert selected.summary.capability_phase == nil
    assert selected.summary.serving_mode == Atom.to_string(mode)
    assert :erpc.call(fixture.peer.node, :sys, :get_state, [client.owner], @budget).suspended_replay.provisional_status == :committed_not_started
    before = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, read_relation: :account_quota_windows, query_predicate: &final_read_query?/1)
    send(selected.sender, {:provider_credits_owner_release, selected.reference})
    assert %{phase: :before_final_read} = ProviderCreditsFixtures.await_before_read!(before)
    ProviderCreditsFixtures.commit_policy_and_release!(before, not revoke?)
    {client, terminal} = receive_client_terminal(selected.client)

    if revoke? do
      assert terminal["type"] in ["error", "response.failed"]
      assert generation_count(fixture) == 1
      assert_unsent_attempt!(selected.summary.attempt_id)
    else
      assert terminal["type"] == "response.completed"
      assert generation_count(fixture) == 2
      connections = fixture.upstream |> FakeUpstream.physical_receipts() |> Enum.filter(&(&1.kind == :generation)) |> Enum.map(& &1.connection_id)
      assert connections == [1, 2]
    end

    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    close_client!(client)
  end

  for mode <- [:full, :lite] do
    @tag credits_negative: true
    test "credit opt-out leaves actual Socket ping interrupt processed and cleanup usable #{mode}" do
      fixture = open!(allow_provider_credits: true)
      setup = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :legacy_windowless)
      configure_runtime_mode!(setup, unquote(mode))
      client = open_owned_socket!(fixture, setup)
      response_id = "resp_synthetic_interrupt"
      hold = make_ref()
      created = CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}})
      accepted = CodexPooler.JSON.encode!(%{"type" => "response.interrupt.accepted", "response_id" => response_id})
      incomplete = CodexPooler.JSON.encode!(%{"type" => "response.incomplete", "response" => %{"id" => response_id, "status" => "incomplete", "output" => [], "incomplete_details" => %{"reason" => "interrupted"}, "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}})
      FakeUpstream.set_mode(fixture.upstream, FakeUpstream.interruptible_websocket_frames([created], response_id: response_id, interrupted: [accepted, incomplete], completion: [], notify: self(), release_ref: hold))
      client = send_client_frame(client, native_payload(setup, native_metadata(), SocketSupport.native_text_input("synthetic interruptible")))
      assert_receive {:fake_upstream_interruptible_open, _handler, ^hold}, @budget
      {conn, websocket, frame} = SocketSupport.public_websocket_receive_text!(client.conn, client.websocket, client.reference)
      assert CodexPooler.JSON.decode!(frame)["type"] == "response.created"
      client = %{client | conn: conn, websocket: websocket}
      ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, false)
      {conn, websocket} = WireSupport.socket_transport_barrier!(client.conn, client.websocket, client.reference)
      client = %{client | conn: conn, websocket: websocket}
      client = send_client_frame(client, %{"type" => "response.interrupt", "response_id" => response_id, "mode" => "discard_partial_items"})
      {client, terminal} = receive_client_terminal(client)
      assert terminal["type"] == "response.incomplete"
      assert FakeUpstream.websocket_interrupts(fixture.upstream) |> Enum.map(& &1.websocket_connection_id) == [1]
      assert generation_count(fixture) == 1
      FakeUpstream.set_mode(fixture.upstream, FakeUpstream.websocket_text_frames([]))
      client = send_client_frame(client, %{"type" => "response.processed", "response_id" => response_id})
      await_processed_frame!(fixture.upstream)
      WireSupport.await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0))
      assert generation_count(fixture) == 1
      close_client!(client)
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    end
  end

  for revocation <- [:none, :policy, :credential_epoch] do
    @tag credits_negative: true
    test "accounted multipart transcribe final read binds forced model and rejects #{revocation}" do
      assert_multipart_transcribe_final_read_binds_forced_model!(unquote(revocation))
    end
  end

  defp assert_multipart_transcribe_final_read_binds_forced_model!(revocation) do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :legacy_windowless, model: "synthetic-unrelated-host", upstream_model: "synthetic-host-provider")
    configure_runtime_mode!(setup, :full)
    FakeUpstream.set_mode(fixture.upstream, {:json, 200, %{"text" => "synthetic transcript"}})
    upload = synthetic_upload!()
    reference = make_ref()
    gate = hold_inserted_attempt!(fixture, setup.identity.id, reference)
    task = Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> ProviderCreditsDispatchSupport.transcribe(setup.authorization, upload) end) end)
    Agent.update(fixture.keeper, &%{&1 | workers: [task.pid | &1.workers]})
    assert_receive {:provider_credits_accounted_attempt, ^reference, executor, attempt_id}, @budget
    assert node(executor) == node()
    attempt = Repo.get!(CodexPooler.Accounting.Attempt, attempt_id)
    assert attempt.upstream_identity_id == setup.identity.id
    assert Repo.get!(CodexPooler.Accounting.Request, attempt.request_id).requested_model == "gpt-4o-transcribe"
    before = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, read_relation: :account_quota_windows, query_predicate: &final_read_query?/1)
    send(executor, {:provider_credits_attempt_release, reference})
    assert %{phase: :before_final_read} = ProviderCreditsFixtures.await_before_read!(before)

    case revocation do
      :policy ->
        ProviderCreditsFixtures.commit_policy_and_release!(before, false)

      :credential_epoch ->
        metadata = CredentialFencing.advance_credential_epoch(Repo.get!(UpstreamIdentity, setup.identity.id))
        Postgrex.query!(before.connection, "UPDATE upstream_identities SET metadata = $1 WHERE id = $2", [metadata, Ecto.UUID.dump!(setup.identity.id)])
        ProviderCreditsFixtures.commit_policy_and_release!(before, true)

      :none ->
        ProviderCreditsFixtures.commit_policy_and_release!(before, true)
    end

    result = Task.await(task, @budget)
    stop_attempt_hold!(gate)

    if revocation == :none do
      assert {:ok, %{status: 200}} = result
      assert [captured] = Enum.filter(FakeUpstream.requests(fixture.upstream), &(&1.path == "/backend-api/transcribe"))
      refute captured.body =~ "synthetic-host-provider"
      refute captured.body =~ "gpt-4o-transcribe"
      assert Repo.reload!(attempt).status == "succeeded"
    else
      assert {:error, %{status: 503}} = result
      refute Enum.any?(FakeUpstream.requests(fixture.upstream), &(&1.path == "/backend-api/transcribe"))
      assert_unsent_attempt!(attempt_id)
    end

    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  @tag credits_negative: true
  test "transcribe forced model cannot borrow the unrelated host's independent Spark allowance" do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :weekly_credit_only, model: "gpt-5.3-codex-spark", upstream_model: "gpt-5.3-codex-spark")
    now = DateTime.utc_now()
    meter = %{"limit_name" => "GPT-5.3-Codex-Spark", "metered_feature" => "codex_bengalfox", "rate_limit" => %{"allowed" => true, "limit_reached" => false, "primary_window" => %{"used_percent" => 0, "limit_window_seconds" => 18_000, "reset_after_seconds" => 18_000, "reset_at" => DateTime.to_unix(DateTime.add(now, 18_000, :second))}}}
    identity = UnboxedFixture.run_unboxed(fn -> ProviderCreditsFixtures.persist_usage!(Repo.get!(UpstreamIdentity, setup.identity.id), Map.put(ProviderCreditsFixtures.usage_payload(:weekly_credit_only, now: now, credits: :none), "additional_rate_limits", [meter]), now) end)
    request = request(fixture, %{setup | identity: identity}, :http_json, :full)
    assert {:ok, response} = execute(request, nil)
    assert admission(response).capacity_basis == :model_allowance
    assert generation_count(fixture) == 1
    options = request.request_options |> RequestOptions.put_transport(upstream_endpoint: "/backend-api/transcribe", transport: "http_multipart") |> RequestOptions.put_payload_context(forced_transcription_model: "gpt-4o-transcribe")
    context = %{selected_context(setup, request, nil) | request_options: options, model: setup.model, reserved: %{request: %{id: nil, pool_id: setup.pool.id}}}
    admission_context = ProviderCreditsAdmission.from_selected(context)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(%{request | url: FakeUpstream.url(fixture.upstream) <> "/backend-api/transcribe", upstream_payload: {:multipart, [{:file, {"synthetic bytes", filename: "audio.wav", content_type: "audio/wav"}}]}, provider_credits_context: admission_context, request_options: options}, nil)
    refute Enum.any?(FakeUpstream.requests(fixture.upstream), &(&1.path == "/backend-api/transcribe"))
  end

  @tag credits_negative: true
  test "epoch replacement and missing or extended admission codecs produce no HTTP or WS generation" do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :included)
    request = request(fixture, setup, :http_json, :full)

    UnboxedFixture.run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, setup.identity.id)
      Repo.update!(Ecto.Changeset.change(identity, metadata: CredentialFencing.advance_credential_epoch(identity)))
    end)

    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request, nil)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(%{request | provider_credits_context: nil}, nil)
    ws = request(fixture, setup, :native_websocket, :full)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(ws, nil)
    attrs = Map.from_struct(ws.provider_credits_context)
    assert {:error, :invalid_admission_context} = ProviderCreditsAdmission.new_context(Map.delete(attrs, :credential_epoch))
    assert {:error, :invalid_admission_context} = ProviderCreditsAdmission.new_context(Map.put(attrs, :qualified_credit_scopes, [%{}]))
    assert generation_count(fixture) == 0
  end

  @tag credits_negative: true
  test "v8 rejects missing old or mismatched authority without touching the provider" do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :included)
    request = request(fixture, setup, :native_websocket, :full)
    context = request.provider_credits_context
    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV8
    {:ok, inner} = WebsocketOwnerRequest.new(%{version: 1, url: request.url, headers: [], payload: request.upstream_payload, timeouts: request.request_options.timeout_config, mapper: :native_codex_responses, upstream_identity_id: setup.identity.id, observation: %{request_id: nil, client_request_id: nil, attempt_id: nil, mode: "full"}, reset_probe: nil, native_codex_response_control: nil, assignment_advertised?: true, connection_bound_continuation?: false, forward_error_body?: false, submission_notification?: false})
    attrs = %{version: 8, request: inner, provider_credits_context: context}
    assert {:ok, _envelope} = WebsocketOwnerRequestV8.new(attrs)
    assert {:error, {:invalid_field, :provider_credits_context}} = WebsocketOwnerRequestV8.new(Map.delete(attrs, :provider_credits_context))
    assert {:error, {:unknown_fields, [:qualified_credit_scopes]}} = WebsocketOwnerRequestV8.new(Map.put(attrs, :qualified_credit_scopes, []))
    assert {:error, {:invalid_field, :provider_credits_context}} = WebsocketOwnerRequestV8.new(%{attrs | provider_credits_context: %{context | upstream_identity_id: Ecto.UUID.generate()}})
    assert {:error, :owner_unavailable} = WebsocketOwnerForwarder.remote_submit_request_v8(Ecto.UUID.generate(), %{pid: self(), epoch: 1, correlation_id: Ecto.UUID.generate()}, inner)
    refute inspect(context) =~ setup.identity.id
    assert generation_count(fixture) == 0
  end

  @tag credits_negative: true
  test "old owner endpoint never receives a downgraded generation or supplies a receipt" do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :included)
    {request, _owner, _session} = owned_request(fixture, setup, :full)

    request = %{
      request
      | request_options:
          RequestOptions.put_transport(request.request_options,
            websocket_owner_forwarder_opts: [node_client: __MODULE__.OldOwnerClient, app_node_names: [Atom.to_string(fixture.peer.node)]]
          )
    }

    assert {:error, %{reason: :owner_unavailable, started: false}} = execute(request, nil)
    assert_received {:old_owner_endpoint, :remote_submit_request_v8}
    refute_received {:old_owner_endpoint, :remote_submit_request_v1}
    assert generation_count(fixture) == 0
  end

  for credits <- [:full, :unknown], policy <- [true, false] do
    @tag credits_negative: true
    test "R5 bound pending reset cannot send a credit-possible probe #{credits} #{policy}" do
      assert_bound_pending_reset_cannot_send_credit_probe!(unquote(policy), unquote(credits))
    end
  end

  defp assert_bound_pending_reset_cannot_send_credit_probe!(policy, credits) do
    fixture = open!(allow_provider_credits: policy)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :weekly_credit_only)
    request = request(fixture, setup, :http_json, :full)
    {request, _redemption} = pending_request(fixture, setup, request, credits)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request, nil)
    ws = %{request | request_options: RequestOptions.for_websocket(request.request_options), provider_credits_context: %{request.provider_credits_context | transport: :native_websocket}}
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(ws, nil)

    UnboxedFixture.run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, setup.identity.id)
      assert identity.metadata["saved_reset_redemption"]["phase"] == "consumed_pending_probe"
      assert identity.metadata["saved_reset_redemption"]["probe"]["token"] == request.provider_credits_context.reset_probe.token
    end)

    assert generation_count(fixture) == 0
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  for mode <- [:full, :lite], credits <- [:full, :unknown] do
    @tag credits_negative: true
    test "R5 remote reused owner cannot confirm the pending identity with #{credits} credits #{mode}" do
      assert_remote_reused_owner_cannot_confirm_pending_identity!(unquote(mode), unquote(credits))
    end
  end

  defp assert_remote_reused_owner_cannot_confirm_pending_identity!(mode, credits) do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :included)
    {request, _owner, upstream_session} = owned_request(fixture, setup, mode)
    assert {:ok, warmup} = execute(request, nil)
    lifecycle = warmup.upstream_websocket_connection.lifecycle_id
    {request, _redemption} = pending_request(fixture, setup, request, credits)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request, nil)
    sibling = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :windowless_credit_only, model: "synthetic-independent-credit")
    assert sibling.identity.id != setup.identity.id
    assert {:ok, independent} = execute(request(fixture, sibling, :http_json, mode), nil)
    assert admission(independent).capacity_basis == :provider_credits
    refute admission(independent).non_credit_guarded_probe
    assert generation_count(fixture) == 2
    assert {:ok, %{lifecycle_id: ^lifecycle}} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [upstream_session], @budget)

    UnboxedFixture.run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, setup.identity.id)
      assert identity.metadata["saved_reset_redemption"]["phase"] == "consumed_pending_probe"
      assert identity.metadata["saved_reset_redemption"]["probe"]["token"] == request.provider_credits_context.reset_probe.token
    end)

    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  for mode <- [:full, :lite], transport <- [:http_json, :http_sse, :native_websocket, :bridged_websocket] do
    @tag credits_negative: true
    test "R6 actual safe probe receipt confirms only its #{transport} #{mode} contract" do
      assert_safe_probe_receipt_confirms_only_its_contract!(unquote(mode), unquote(transport))
    end
  end

  defp assert_safe_probe_receipt_confirms_only_its_contract!(mode, transport) do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :weekly_credit_only)
    configure_runtime_mode!(setup, mode)
    consume_pending!(fixture, setup)
    selected = request(fixture, setup, transport, mode)
    {selected, _redemption} = pending_request(fixture, setup, selected, :none, actual_consume: true)
    assert {:ok, result} = execute(selected, nil)
    if transport == :http_sse, do: assert(drain_http(result) =~ "response.completed")
    receipt = admission(result)
    assert receipt.non_credit_guarded_probe

    UnboxedFixture.run_unboxed(fn ->
      context = selected_context(setup, selected, receipt)
      SideEffects.before_finalize_success(context, context.request_options)
      confirmed = Repo.reload!(setup.identity).metadata["saved_reset_redemption"]
      assert confirmed["phase"] == "confirmed_by_upstream"
      assert confirmed["non_credit_confirmation"]["scope"]["serving_mode"] == Atom.to_string(mode)
      assert confirmed["non_credit_confirmation"]["scope"]["transport"] == Atom.to_string(transport)
    end)

    followup = request(fixture, setup, transport, mode)
    assert {:ok, resumed} = execute(followup, nil)
    if transport == :http_sse, do: assert(drain_http(resumed) =~ "response.completed")
    assert admission(resumed).capacity_basis == :recovered_included
    refute admission(resumed).non_credit_guarded_probe
    assert generation_count(fixture) == 2
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 1
  end

  @tag credits_negative: true
  test "R6 one safe non-credit lease sends and only its final admission may confirm" do
    fixture = open!()
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :weekly_credit_only)
    configure_runtime_mode!(setup, :full)
    request = request(fixture, setup, :http_json, :full)
    consume_pending!(fixture, setup)
    {request, redemption} = pending_request(fixture, setup, request, :none, actual_consume: true)
    competing = ResetProbe.new() |> ResetProbe.bind(setup.assignment.id, setup.identity.id, setup.model.exposed_model_id, request.provider_credits_context.route_class) |> elem(1)
    assert {:error, :unavailable} = UnboxedFixture.run_unboxed(fn -> ProbeLease.claim(setup.identity.id, redemption["generation"], redemption["attempt_id"], competing) end)
    assert {:ok, response} = execute(request, nil)
    receipt = admission(response)
    assert receipt.capacity_basis == :recovered_included
    assert receipt.non_credit_guarded_probe

    UnboxedFixture.run_unboxed(fn ->
      context = selected_context(setup, request, receipt)
      SideEffects.before_finalize_success(%{context | provider_credits_admission: nil}, context.request_options)
      assert Repo.get!(UpstreamIdentity, setup.identity.id).metadata["saved_reset_redemption"]["phase"] == "consumed_pending_probe"
      SideEffects.before_finalize_success(context, context.request_options)
      assert Repo.get!(UpstreamIdentity, setup.identity.id).metadata["saved_reset_redemption"]["phase"] == "confirmed_by_upstream"
    end)

    followup = request(fixture, setup, :http_json, :full)

    UnboxedFixture.run_unboxed(fn ->
      model = Repo.reload!(setup.model)
      source = model.metadata["source_assignment_models"][setup.assignment.id]

      siblings =
        Enum.map([:windowless_credit_only, :windowless_unknown], fn state ->
          ProviderCreditsFixtures.runtime_setup!(fixture, :a, state, model: "synthetic-exhausted-partition-#{state}")
        end)

      sibling_ids = Enum.map(siblings, & &1.assignment.id)
      sources = Map.new(siblings, fn sibling -> {sibling.assignment.id, Map.put(source, "supports_parallel_tool_calls", false)} end)
      sources = Map.put(sources, setup.assignment.id, source)
      Repo.update!(Ecto.Changeset.change(model, metadata: Map.merge(model.metadata, %{"source_assignment_ids" => [setup.assignment.id | sibling_ids], "source_assignment_models" => sources})))
    end)

    assert {:ok, %{status: 200}} =
             UnboxedFixture.run_unboxed(fn ->
               {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
               Service.execute(auth, @endpoint, %{"model" => setup.model.exposed_model_id, "input" => []}, followup.request_options)
             end)

    assert {:ok, resumed} = execute(followup, nil)
    assert admission(resumed).capacity_basis == :recovered_included
    refute admission(resumed).non_credit_guarded_probe

    for changed <- [%{followup.provider_credits_context | pool_id: fixture.pools.b.id, pool_upstream_assignment_id: fixture.assignments[{:b, :weekly_credit_only}].id}, %{followup.provider_credits_context | upstream_model: "synthetic-unrelated-model"}, %{followup.provider_credits_context | serving_mode: :lite}, %{followup.provider_credits_context | route_class: "http_compact"}] do
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(%{followup | provider_credits_context: changed}, nil)
    end

    confirmed =
      UnboxedFixture.run_unboxed(fn ->
        identity = Repo.get!(UpstreamIdentity, setup.identity.id)
        confirmed = identity.metadata["saved_reset_redemption"]
        assert confirmed["non_credit_confirmation"]["version"] == 1
        assert confirmed["non_credit_confirmation"]["credential_epoch"] == CredentialFencing.credential_epoch(identity)
        Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "saved_reset_redemption", Map.delete(confirmed, "non_credit_confirmation"))))
        confirmed
      end)

    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(followup, nil)

    UnboxedFixture.run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, setup.identity.id)
      expired = Map.put(confirmed, "deadline_at", DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1, :second)))
      Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "saved_reset_redemption", expired)))
    end)

    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(followup, nil)

    assert generation_count(fixture) == 3
    assert FakeUpstream.physical_counts(fixture.upstream).consume == 1
  end

  @tag credits_negative: true
  test "policy denial after reservation settles not-applicable usage and releases funds without demotion" do
    fixture = open!(allow_provider_credits: true)
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :legacy_windowless)
    request = request(fixture, setup, :http_json, :full)

    context =
      UnboxedFixture.run_unboxed(fn ->
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
        {:ok, reserved} = Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id, "input" => "synthetic"}, %{endpoint: @endpoint, transport: "http_json"})
        {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment, %{transport: "http_json"})
        %{selected_context(setup, request, nil) | auth: auth, reserved: reserved, attempt: attempt}
      end)

    ProviderCreditsFixtures.commit_policy!(fixture, :legacy_windowless, false, fixture.peer.node)
    assert {:error, denial} = execute(request, nil)
    assert {:error, %{status: 503}} = UnboxedFixture.run_unboxed(fn -> Finalization.finalize_policy_denial(denial, context, 0) end)

    UnboxedFixture.run_unboxed(fn ->
      persisted = Repo.reload!(context.reserved.request)
      attempt = Repo.reload!(context.attempt)
      assert persisted.status == "failed"
      assert persisted.usage_status == "not_applicable"
      assert attempt.usage_status == "not_applicable"
      refute Accounting.reservation_outstanding?(persisted)
      entries = Accounting.list_ledger_entries_for_request(persisted)
      assert [settlement] = Enum.filter(entries, &(&1.entry_kind == "settlement"))
      assert settlement.usage_status == "not_applicable"
      assert settlement.input_tokens == nil
      assert settlement.output_tokens == nil
      assert settlement.total_tokens == nil
      assert settlement.settled_cost_micros == nil or Decimal.equal?(settlement.settled_cost_micros, 0)
      assert Enum.count(entries, &(&1.entry_kind == "release")) == 1
      assert Repo.aggregate(from(d in CodexPooler.Gateway.Persistence.BridgeDemotion, where: d.pool_upstream_assignment_id == ^setup.assignment.id), :count) == 0
    end)

    assert generation_count(fixture) == 0
  end

  defmodule OldOwnerClient do
    def connected_app_nodes, do: Node.list(:connected)

    def call_owner(_node, module, function, args, _timeout) do
      send(self(), {:old_owner_endpoint, function})
      {:error, {:exception, :undef, [{module, function, args, []}]}}
    end
  end

  defp final_read_query?(query), do: ProviderCreditsFixtures.snapshot_query?(query) and String.contains?(query, ~s("pool_upstream_assignments"))

  @tag credits_negative: true
  test "R4 ambiguous physical consume stays latched while independent included success cannot confirm it" do
    fixture = open!(allow_provider_credits: true)
    subject = ProviderCreditsFixtures.runtime_setup!(fixture, :a, :weekly_credit_only)
    control = ProviderCreditsFixtures.runtime_setup!(fixture, :b, :included, model: "synthetic-independent-control")
    configure_runtime_mode!(control, :full)

    FakeUpstream.set_mode(
      fixture.upstream,
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => :close_before_headers,
         @endpoint => {200, %{"id" => "resp_synthetic_independent", "object" => "response", "status" => "completed", "output" => []}}
       }}
    )

    original_latch =
      UnboxedFixture.run_unboxed(fn ->
        identity = Repo.get!(UpstreamIdentity, subject.identity.id)
        now = DateTime.utc_now()
        bank = %{"status" => "reported", "available_count" => 1, "source" => "codex_usage_api", "path_style" => "codex_api", "observed_at" => DateTime.to_iso8601(now), "usage_path" => "/api/codex/usage", "reason" => nil}
        identity = Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "saved_resets", bank)))
        assert {:error, :saved_reset_consume_outcome_ambiguous} = SavedResetRedemption.redeem(subject.assignment)
        latch = Repo.reload!(identity).metadata["saved_reset_redemption"]
        assert latch["phase"] == "consuming"
        assert latch["result"] == nil
        assert latch["provider_replay"]["provider_dispatches"] == 1
        assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(subject.assignment)
        latch
      end)

    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request(fixture, subject, :http_json, :full), nil)
    assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request(fixture, subject, :native_websocket, :full), nil)

    result =
      UnboxedFixture.run_unboxed(fn ->
        {:ok, auth} = Access.authenticate_authorization_header(control.authorization)
        options = RequestOptions.build(%{transport: "http_json", model_serving_mode: "full", model_serving_mode_configured: "full", model_serving_mode_source: "override"}, @endpoint, %{})
        Service.execute(auth, @endpoint, %{"model" => control.model.exposed_model_id, "input" => []}, options)
      end)

    assert {:ok, %{status: 200}} = result

    UnboxedFixture.run_unboxed(fn ->
      assert Repo.reload!(subject.identity).metadata["saved_reset_redemption"] == original_latch
      attempt = Repo.one!(from attempt in CodexPooler.Accounting.Attempt, where: attempt.upstream_identity_id == ^control.identity.id)
      assert attempt.status == "succeeded"
      assert attempt.response_metadata["provider_credits_admission"]["capacity_basis"] in ["ordinary_provider_permission", "included_window"]
      refute attempt.response_metadata["provider_credits_admission"]["non_credit_guarded_probe"]
      request = Repo.get!(CodexPooler.Accounting.Request, attempt.request_id)
      refute Accounting.reservation_outstanding?(request)
      assert Repo.aggregate(from(subject_attempt in CodexPooler.Accounting.Attempt, where: subject_attempt.upstream_identity_id == ^subject.identity.id), :count) == 0
      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(subject.assignment)
      assert Repo.reload!(subject.identity).metadata["saved_reset_redemption"] == original_latch
    end)

    assert [generation] = Enum.filter(FakeUpstream.requests(fixture.upstream), &(&1.path == @endpoint))
    assert generation.json["model"] == control.model.upstream_model_id

    assert FakeUpstream.physical_counts(fixture.upstream).consume == 1
    assert FakeUpstream.physical_counts(fixture.upstream).http_generation == 1
  end

  for mode <- [:full, :lite], transport <- [:http_sse, :native_websocket, :bridged_websocket], enabled <- [true, false], model <- ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"] do
    @tag credits_negative: true
    test "fresh WHAM finite credits admit actual #{model} #{transport} #{mode} enabled=#{enabled}" do
      assert_fresh_wham_finite_credits_admit_model!(unquote(enabled), unquote(model), unquote(transport), unquote(mode))
    end
  end

  defp assert_fresh_wham_finite_credits_admit_model!(enabled, model, transport, mode) do
    fixture = open!(allow_provider_credits: enabled)
    setup = luna_setup!(fixture, :a, model: model)
    selected = request(fixture, setup, transport, mode)

    if enabled do
      assert {:ok, result} = execute(selected, nil)
      receipt = admission(result)
      assert receipt.capacity_basis == :provider_credits
      refute receipt.non_credit_guarded_probe
      assert receipt.context.serving_mode == mode
      assert receipt.context.transport == transport
      assert receipt.context.upstream_model == model
      assert receipt.context.upstream_identity_id == setup.identity.id
      if transport == :http_sse, do: assert(drain_http(result) =~ "response.completed")
      assert generation_count(fixture) == 1
      assert [generation] = Enum.filter(FakeUpstream.requests(fixture.upstream), &(&1.path == @endpoint))
      assert generation.json["model"] == model
    else
      assert {:error, %{reason: :provider_credits_policy_denied, started: false, reason_codes: reasons}} = execute(selected, nil)
      assert "provider_credits_disabled" in reasons
      assert generation_count(fixture) == 0
    end

    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    UnboxedFixture.run_unboxed(fn -> refute Repo.reload!(setup.identity).metadata["saved_reset_redemption"] end)
  end

  for mode <- [:full, :lite] do
    test "fresh credit permission admits actual HTTP JSON transport #{mode}" do
      fixture = open!(allow_provider_credits: true)
      setup = luna_setup!(fixture, :a)
      assert {:ok, response} = execute(request(fixture, setup, :http_json, unquote(mode)), nil)
      assert admission(response).capacity_basis == :provider_credits
      assert admission(response).context.transport == :http_json
      assert generation_count(fixture) == 1
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    end

    for denial <- [:workspace, :provider_refusal, :credential_epoch, :assignment_disabled, :reauth_required, :stale_permission] do
      @tag credits_negative: true
      test "provider credit permission retains final #{denial} denial over HTTP and Mint #{mode}" do
        fixture = open!(allow_provider_credits: true)
        setup = luna_setup!(fixture, :a)
        http = request(fixture, setup, :http_sse, unquote(mode))
        websocket = request(fixture, setup, :native_websocket, unquote(mode))

        case unquote(denial) do
          :workspace ->
            persist_runtime_denial!(setup.identity)

          :provider_refusal ->
            UnboxedFixture.run_unboxed(fn ->
              now = DateTime.utc_now()
              assert {:ok, [_window]} = Windows.upsert_quota_windows_from_codex_headers(Repo.reload!(setup.identity), weekly_denial_headers(now), now, "gpt-6-luna", "usage_limit_reached")
            end)

          :credential_epoch ->
            UnboxedFixture.run_unboxed(fn ->
              identity = Repo.reload!(setup.identity)
              Repo.update!(Ecto.Changeset.change(identity, metadata: CredentialFencing.advance_credential_epoch(identity)))
            end)

          :assignment_disabled ->
            UnboxedFixture.run_unboxed(fn -> Repo.update!(Ecto.Changeset.change(setup.assignment, eligibility_status: "ineligible")) end)

          :reauth_required ->
            UnboxedFixture.run_unboxed(fn -> Repo.update!(Ecto.Changeset.change(setup.identity, status: UpstreamIdentity.reauth_required_status())) end)

          :stale_permission ->
            UnboxedFixture.run_unboxed(fn ->
              observed_at = DateTime.add(DateTime.utc_now(), -Evidence.freshness_ttl_seconds() - 1, :second)
              identity = Repo.reload!(setup.identity)
              assert {:ok, facts} = CapacityFactsStore.load(identity.metadata)
              stale = %{facts | observed_at: observed_at}
              epoch = CredentialFencing.credential_epoch(identity)
              metadata = Map.put(identity.metadata, CapacityFactsStore.metadata_key(), CapacityFactsStore.encode!(stale, epoch))
              Repo.update!(Ecto.Changeset.change(identity, metadata: metadata))
              refute CapacityFactsStore.fresh?(stale, epoch, DateTime.utc_now())
            end)
        end

        assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(http, nil)
        assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(websocket, nil)
        assert generation_count(fixture) == 0
        assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
      end
    end

    for refusal <- [:older_weekly, :older_workspace] do
      @tag credits_negative: true
      test "fresh WHAM Luna credit authority supersedes only an older ordinary weekly refusal not #{refusal} #{mode}" do
        fixture = open!(allow_provider_credits: true)
        setup = luna_setup!(fixture, :a)
        now = DateTime.utc_now()
        denied_at = DateTime.add(now, -1, :second)
        headers = weekly_denial_headers(now)
        headers = if unquote(refusal) == :older_workspace, do: List.keyreplace(headers, "x-codex-rate-limit-reached-type", 0, {"x-codex-rate-limit-reached-type", "workspace_member_credits_depleted"}), else: headers

        UnboxedFixture.run_unboxed(fn ->
          assert {:ok, [_window]} = Windows.upsert_quota_windows_from_codex_headers(Repo.reload!(setup.identity), headers, denied_at, "gpt-6-luna", "usage_limit_reached")
        end)

        identity = refresh_luna_usage!(fixture, setup, :weekly_credit_only, now: now)
        selected = request(fixture, %{setup | identity: identity}, :http_sse, unquote(mode))

        if unquote(refusal) == :older_weekly do
          assert {:ok, result} = execute(selected, nil)
          assert admission(result).capacity_basis == :provider_credits
          assert drain_http(result) =~ "response.completed"
          assert generation_count(fixture) == 1
        else
          assert {:error, %{reason: :provider_credits_policy_denied, started: false, reason_codes: reasons}} = execute(selected, nil)
          assert "provider_denied" in reasons
          assert generation_count(fixture) == 0
        end

        assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
      end
    end

    @tag credits_negative: true
    test "shared credit identity rechecks the other replica's opt-out before either Pool sends #{mode}" do
      fixture = open!(allow_provider_credits: true)
      first = luna_setup!(fixture, :a)
      second = luna_setup!(fixture, :b)

      assert first.identity.id == second.identity.id
      refute first.pool.id == second.pool.id

      for {setup, admitted_count} <- [{first, 1}, {second, 2}] do
        ProviderCreditsFixtures.commit_policy!(fixture, :weekly_credit_only, true)
        selected = request(fixture, setup, :http_sse, unquote(mode))
        assert {:ok, positive} = execute(selected, nil)
        assert admission(positive).capacity_basis == :provider_credits
        assert drain_http(positive) =~ "response.completed"
        assert generation_count(fixture) == admitted_count
        reference = make_ref()
        worker = ProviderCreditsFixtures.start_peer_work!(fixture, {ProviderCreditsDispatchSupport, :held_http, [selected, self(), reference]})
        assert_receive {:dispatch_reader_ready, ^reference, reader, backend}, @budget
        barrier = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, backend_pid: backend)
        send(reader, {:dispatch_read, reference})
        assert %{phase: :before_final_read, backend_pid: ^backend} = ProviderCreditsFixtures.await_before_read!(barrier)
        ProviderCreditsFixtures.commit_policy_and_release!(barrier, false)
        assert {:error, %{reason: :provider_credits_policy_denied, started: false, reason_codes: reasons}} = await_worker(worker)
        assert "provider_credits_disabled" in reasons
        assert generation_count(fixture) == admitted_count
      end

      assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    end

    @tag credits_negative: true
    test "credit final read may complete after opt-out but the next Pool gets no send #{mode}" do
      fixture = open!(allow_provider_credits: true)
      first = luna_setup!(fixture, :a)
      second = luna_setup!(fixture, :b)
      assert first.identity.id == second.identity.id
      refute first.pool.id == second.pool.id
      barrier = ProviderCreditsFixtures.after_read_barrier!(fixture, first.identity.id, node: fixture.peer.node)
      worker = ProviderCreditsFixtures.start_peer_work!(fixture, {ProviderCreditsDispatchSupport, :execute_terminal, [request(fixture, first, :http_sse, unquote(mode)), nil]})
      reference = barrier.ref
      assert_receive {:provider_credits_barrier, ^reference, :after_final_read, emitter}, @budget
      assert emitter == worker.pid
      assert generation_count(fixture) == 0
      ProviderCreditsFixtures.commit_policy!(fixture, :weekly_credit_only, false)
      ProviderCreditsFixtures.release_barrier!(barrier)
      assert {:ok, response} = await_worker(worker)
      assert admission(response).capacity_basis == :provider_credits
      refute admission(response).non_credit_guarded_probe
      assert response.terminal_completed?
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(request(fixture, second, :http_sse, unquote(mode)), nil)
      assert generation_count(fixture) == 1
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
    end

    @tag credits_negative: true
    test "actual remote owner v8 carries provider credit receipts across anchored sends and final opt-out #{mode}" do
      fixture = open!(allow_provider_credits: true)
      setup = luna_setup!(fixture, :b)
      mode = unquote(mode)
      configure_runtime_mode!(setup, mode)
      client = open_owned_socket!(fixture, setup)
      assert node(client.owner) == fixture.peer.node
      metadata = native_metadata()
      FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_luna_opener", [synthetic_assistant_item("msg_synthetic_luna_opener")]))
      {client, opener} = send_socket_turn!(client, native_payload(setup, metadata, SocketSupport.native_text_input("synthetic Luna opener")))
      assert opener["type"] == "response.completed"
      assert {:ok, connection} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [client.upstream_session], @budget)
      lifecycle = connection.lifecycle_id
      FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_luna_continued", []))
      positive = hold_socket_generation!(client, controlled_generation_payload(setup, metadata, :anchored, opener["response"]["id"]))
      assert_handoff_contract!(positive.summary, :anchored, mode)
      send(positive.sender, {:provider_credits_owner_release, positive.reference})
      {client, continued} = receive_client_terminal(positive.client)
      assert continued["type"] == "response.completed"
      retained = continued["response"]["id"]
      assert_active_anchor!(client.codex_session_id, retained)
      assert generation_count(fixture) == 2
      attempt = Repo.get!(CodexPooler.Accounting.Attempt, positive.summary.attempt_id)
      assert attempt.status == "succeeded"
      assert attempt.response_metadata["provider_credits_admission"]["capacity_basis"] == "provider_credits"
      refute attempt.response_metadata["provider_credits_admission"]["non_credit_guarded_probe"]
      assert attempt.transport == "websocket"
      logged = Repo.get!(CodexPooler.Accounting.Request, positive.summary.request_id)
      assert attempt.request_id == logged.id
      assert logged.requested_model == "gpt-6-luna"
      assert logged.request_metadata["routing"]["model_serving_mode"] == Atom.to_string(mode)
      refute Accounting.reservation_outstanding?(logged)
      settlement = Repo.get_by!(CodexPooler.Accounting.LedgerEntry, request_id: logged.id, entry_kind: "settlement")
      assert settlement.usage_status == "usage_known"
      assert {settlement.input_tokens, settlement.output_tokens, settlement.total_tokens} == {1, 1, 2}
      assert Enum.map(Enum.filter(FakeUpstream.physical_receipts(fixture.upstream), &(&1.kind == :generation)), & &1.connection_id) == [1, 1]
      selected = hold_socket_generation!(client, controlled_generation_payload(setup, native_metadata(), :anchored, retained))
      assert_handoff_contract!(selected.summary, :anchored, mode)
      before = ProviderCreditsFixtures.before_read_barrier!(fixture, setup.identity.id, read_relation: :account_quota_windows, query_predicate: &final_read_query?/1)
      send(selected.sender, {:provider_credits_owner_release, selected.reference})
      assert %{phase: :before_final_read} = ProviderCreditsFixtures.await_before_read!(before)
      ProviderCreditsFixtures.commit_policy_and_release!(before, false)
      {client, denied} = receive_client_terminal(selected.client)
      assert denied["type"] in ["error", "response.failed"]
      assert generation_count(fixture) == 2
      assert_unsent_attempt!(selected.summary.attempt_id)
      assert_active_anchor!(client.codex_session_id, retained)
      assert {:ok, %{lifecycle_id: ^lifecycle}} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [client.upstream_session], @budget)
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
      close_client!(client)
    end

    @tag credits_negative: true
    test "provider credit capacity cannot probe-confirm a consumed pending bank on a reused remote owner #{mode}" do
      fixture = open!(allow_provider_credits: true)
      setup = luna_setup!(fixture, :b)
      {selected, _owner, upstream_session} = owned_request(fixture, setup, unquote(mode))
      assert {:ok, warmup} = execute(selected, nil)
      assert admission(warmup).capacity_basis == :provider_credits
      lifecycle = warmup.upstream_websocket_connection.lifecycle_id
      consume_pending!(fixture, setup)
      {selected, _redemption} = pending_request(fixture, setup, selected, :full, actual_consume: true)
      fresh = refresh_luna_usage!(fixture, setup, :weekly_credit_only, credits: :full)
      selected = %{selected | identity: fresh}
      before = fresh.metadata["saved_reset_redemption"]
      assert before["phase"] == "consumed_pending_probe"
      assert before["probe"]["token"] == selected.provider_credits_context.reset_probe.token
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(selected, nil)
      assert generation_count(fixture) == 1
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 1
      assert {:ok, %{lifecycle_id: ^lifecycle}} = :erpc.call(fixture.peer.node, UpstreamWebsocketSession, :live_connection, [upstream_session], @budget)

      UnboxedFixture.run_unboxed(fn ->
        identity = Repo.reload!(setup.identity)
        assert identity.metadata["saved_reset_redemption"] == before
        assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(setup.assignment)
      end)

      assert FakeUpstream.physical_counts(fixture.upstream).consume == 1
    end

    @tag credits_negative: true
    test "independent provider credit success cannot confirm another identity's consumed bank #{mode}" do
      fixture = open!(allow_provider_credits: true)
      subject = luna_setup!(fixture, :a)
      consume_pending!(fixture, subject)
      selected = request(fixture, subject, :http_sse, unquote(mode))
      {selected, _redemption} = pending_request(fixture, subject, selected, :full, actual_consume: true)
      fresh = refresh_luna_usage!(fixture, subject, :weekly_credit_only, credits: :full)
      selected = %{selected | identity: fresh}
      original = fresh.metadata["saved_reset_redemption"]
      control = luna_setup!(fixture, :b, identity_state: :windowless_credit_only)
      assert control.identity.id != subject.identity.id
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(selected, nil)
      finish_luna_service_stream!(fixture, control, unquote(mode))

      UnboxedFixture.run_unboxed(fn ->
        identity = Repo.reload!(subject.identity)
        assert identity.metadata["saved_reset_redemption"] == original
        assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(subject.assignment)
        attempt = Repo.one!(from attempt in CodexPooler.Accounting.Attempt, where: attempt.upstream_identity_id == ^control.identity.id)
        assert attempt.status == "succeeded"
        assert attempt.response_metadata["provider_credits_admission"]["capacity_basis"] == "provider_credits"
        refute attempt.response_metadata["provider_credits_admission"]["non_credit_guarded_probe"]
        refute Accounting.reservation_outstanding?(Repo.get!(CodexPooler.Accounting.Request, attempt.request_id))
      end)

      assert generation_count(fixture) == 1
      assert FakeUpstream.physical_counts(fixture.upstream).consume == 1
    end
  end

  for mode <- [:full, :lite], boundary <- [:other_model, :short, :monthly, :mixed, :windowless, :codex_source, :unlimited, :weekly_primary_extra] do
    @tag credits_negative: true
    test "Mint final admission distinguishes usable #{boundary} permission from malformed windows #{mode}" do
      assert_final_admission_distinguishes_permission_from_malformed_windows!(unquote(boundary), unquote(mode))
    end
  end

  defp assert_final_admission_distinguishes_permission_from_malformed_windows!(boundary, mode) do
    fixture = open!(allow_provider_credits: true)
    setup = luna_setup!(fixture, :a)
    state = %{short: :short_credit_only, monthly: :monthly_credit_only, mixed: :mixed_credit_only, windowless: :windowless_credit_only}[boundary] || :weekly_credit_only
    usage = ProviderCreditsFixtures.usage_payload(state, credits: if(boundary == :unlimited, do: :unlimited, else: :fractional)) |> Map.put("rate_limit_reset_credits", %{"available_count" => 0})
    usage = if boundary == :weekly_primary_extra, do: usage |> put_in(["rate_limit", "primary_window"], get_in(usage, ["rate_limit", "secondary_window"])), else: usage
    routes = ProviderCreditsFixtures.usage_routes(usage)
    routes = if boundary == :codex_source, do: routes |> Map.put("/api/codex/usage", {404, %{}}) |> Map.put("/backend-api/wham/usage", {404, %{}}), else: routes |> Map.put("/api/codex/usage", {404, %{}}) |> Map.put("/backend-api/codex/usage", {404, %{}})
    FakeUpstream.set_mode(fixture.upstream, {:path_json, routes})

    identity =
      UnboxedFixture.run_unboxed(fn ->
        assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(setup.identity), setup.assignment)
        assert {:ok, facts} = CapacityFactsStore.load(identity.metadata)
        assert facts.source_kind == if(boundary == :codex_source, do: :codex_usage, else: :wham_usage)
        assert facts.credit_permission == if(boundary == :weekly_primary_extra, do: :unknown, else: :available)
        identity
      end)

    FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_credit_permission", []))
    model = if boundary == :other_model, do: UnboxedFixture.run_unboxed(fn -> Repo.update!(Ecto.Changeset.change(setup.model, upstream_model_id: "gpt-6-astra")) end), else: setup.model
    selected = request(fixture, %{setup | identity: identity, model: model}, :native_websocket, mode)

    if boundary == :weekly_primary_extra do
      assert {:error, %{reason: :provider_credits_policy_denied, started: false}} = execute(selected, nil)
      assert generation_count(fixture) == 0
    else
      assert {:ok, response} = execute(selected, nil)
      assert admission(response).capacity_basis == :provider_credits
      assert admission(response).context.upstream_model == model.upstream_model_id
      assert generation_count(fixture) == 1
      assert [generation] = Enum.filter(FakeUpstream.requests(fixture.upstream), &(&1.path == @endpoint))
      assert generation.json["model"] == model.upstream_model_id
    end

    assert FakeUpstream.physical_counts(fixture.upstream).consume == 0
  end

  defp luna_setup!(fixture, pool, opts \\ []) do
    model = Keyword.get(opts, :model, "gpt-6-luna")
    setup = ProviderCreditsFixtures.runtime_setup!(fixture, pool, Keyword.get(opts, :identity_state, :weekly_credit_only), model: model, upstream_model: model)
    %{setup | identity: refresh_luna_usage!(fixture, setup, :weekly_credit_only)}
  end

  defp refresh_luna_usage!(fixture, setup, state, opts \\ []) do
    usage = ProviderCreditsFixtures.usage_payload(state, Keyword.put_new(opts, :credits, :fractional)) |> Map.put("rate_limit_reset_credits", %{"available_count" => 0})
    routes = ProviderCreditsFixtures.usage_routes(usage) |> Map.put("/api/codex/usage", {404, %{}}) |> Map.put("/backend-api/codex/usage", {404, %{}})
    FakeUpstream.set_mode(fixture.upstream, {:path_json, routes})

    identity =
      UnboxedFixture.run_unboxed(fn ->
        refresh_opts = if opts[:now], do: [observed_at: opts[:now]], else: []
        assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(setup.identity), setup.assignment, refresh_opts)
        assert {:ok, facts} = CapacityFactsStore.load(identity.metadata)
        assert facts.source_kind == :wham_usage
        assert facts.included_permission == :exhausted
        assert facts.credit_permission == :available
        assert facts.unlimited == false
        assert [%{window_kind: "secondary", window_minutes: 10_080}] = Enum.map(facts.account_windows, &Map.take(&1, [:window_kind, :window_minutes]))
        identity
      end)

    FakeUpstream.set_mode(fixture.upstream, {:json, 200, %{"id" => "resp_synthetic_luna_dispatch", "object" => "response", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}})
    identity
  end

  defp weekly_denial_headers(now) do
    [{"x-codex-secondary-used-percent", "100"}, {"x-codex-secondary-window-minutes", "10080"}, {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(DateTime.add(now, 7_200, :second)))}, {"x-codex-rate-limit-reached-type", "rate_limit_reached"}]
  end

  defp finish_luna_service_stream!(fixture, setup, mode) do
    completed = %{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_independent_luna", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}
    FakeUpstream.set_mode(fixture.upstream, FakeUpstream.sse_stream([completed]))

    UnboxedFixture.run_unboxed(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: Atom.to_string(mode), created_at: now, updated_at: now})
      assert {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      payload = %{"model" => setup.model.exposed_model_id, "input" => [], "stream" => true}
      options = RequestOptions.build(%{transport: "http_sse", upstream_endpoint: @endpoint, model_serving_mode: Atom.to_string(mode), model_serving_mode_configured: Atom.to_string(mode), model_serving_mode_source: "override"}, @endpoint, payload)
      assert {:ok, %{stream: stream}} = Service.execute(auth, @endpoint, payload, options)
      conn = Phoenix.ConnTest.build_conn() |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)
      assert {:ok, conn} = stream.(conn)
      assert conn.resp_body =~ "response.completed"
    end)
  end

  defp open!(opts \\ []) do
    completed = %{"id" => "resp_synthetic_gate", "object" => "response", "status" => "completed", "model" => "synthetic", "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}
    ProviderCreditsFixtures.open!(Keyword.put(opts, :mode, {:json, 200, completed}))
  end

  defp request(fixture, setup, transport, mode) do
    completed = %{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_gate", "status" => "completed", "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}
    if transport == :http_sse, do: FakeUpstream.set_mode(fixture.upstream, FakeUpstream.sse_stream([completed]))
    payload = %{"model" => setup.model.upstream_model_id, "input" => [], "stream" => transport != :http_json}
    options = RequestOptions.build(%{transport: if(transport in [:native_websocket, :bridged_websocket], do: "websocket", else: Atom.to_string(transport)), upstream_endpoint: @endpoint, receive_timeout_ms: 60_000, model_serving_mode_configured: Atom.to_string(mode), model_serving_mode: Atom.to_string(mode), model_serving_mode_source: "override"}, @endpoint, payload)
    options = if transport == :bridged_websocket, do: RequestOptions.put_transport(options, upstream_websocket_bridge?: true), else: options
    options = RequestOptions.put_routing(options, effective_model: setup.model.exposed_model_id)
    context = %ProviderCreditsAdmission.Context{version: 1, pool_id: setup.assignment.pool_id, pool_upstream_assignment_id: setup.assignment.id, upstream_identity_id: setup.identity.id, credential_epoch: CredentialFencing.credential_epoch(setup.identity), model: setup.model.exposed_model_id, upstream_model: setup.model.upstream_model_id, serving_mode: mode, transport: transport, route_class: options.transport.route_class, request_id: nil, attempt_id: nil, reset_probe: nil, redemption_generation: nil, redemption_attempt_id: nil}
    body = if transport in [:native_websocket, :bridged_websocket], do: Map.put(payload, "type", "response.create"), else: payload
    %UpstreamDispatch.Request{url: FakeUpstream.url(fixture.upstream) <> @endpoint, token: "synthetic-fixture-token", upstream_payload: CodexPooler.JSON.encode!(body), original_payload: payload, identity: setup.identity, provider_credits_context: context, request_options: options, writer: &ProviderCreditsDispatchSupport.ignore_frame/1, routing_hint_authorized?: false, assignment_advertised?: true}
  end

  defp owned_request(fixture, setup, mode) do
    {:ok, auth} = UnboxedFixture.run_unboxed(fn -> Access.authenticate_authorization_header(setup.authorization) end)
    {:ok, session} = UnboxedFixture.run_unboxed(fn -> Websocket.start_codex_session(auth, %{session_header: "synthetic-owner-#{Ecto.UUID.generate()}", owner_instance_id: Atom.to_string(fixture.peer.node)}) end)
    persistence = :erpc.call(fixture.peer.node, WebsocketOwnerNodeHarness, :real_persistence_boundary, [], @budget)
    {:ok, owner} = :erpc.call(fixture.peer.node, WebsocketOwnerSession, :start_owner, [[codex_session_id: session.id, owner_lease_token: session.owner_lease_token, owner_instance_id: session.owner_instance_id, persistence: persistence, owner_renewal_ms: 60_000]], @budget)
    {:ok, downstream} = WebsocketOwnerSession.attach_downstream(owner, %{pid: self(), correlation_id: Ecto.UUID.generate()})
    session = UnboxedFixture.run_unboxed(fn -> Repo.get!(CodexSession, session.id) end)
    request = request(fixture, setup, :native_websocket, mode)

    options =
      request.request_options
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.put_transport(
        websocket_owner_forwarding_enabled?: true,
        websocket_owner_session: session,
        websocket_owner_lease_token: session.owner_lease_token,
        websocket_owner_downstream: downstream,
        websocket_owner_downstream_epoch: downstream.epoch,
        websocket_owner_proxy_instance_id: Atom.to_string(node()),
        websocket_owner_instance_id: session.owner_instance_id,
        websocket_owner_forwarder_opts: [app_node_names: [Atom.to_string(fixture.peer.node)]]
      )

    state = :erpc.call(fixture.peer.node, :sys, :get_state, [owner], @budget)
    {%{request | request_options: options}, owner, state.upstream_pid}
  end

  defp pending_request(_fixture, setup, request, credits, opts \\ []) do
    UnboxedFixture.run_unboxed(fn ->
      now = DateTime.utc_now()
      identity = ProviderCreditsFixtures.persist_usage!(Repo.get!(UpstreamIdentity, setup.identity.id), ProviderCreditsFixtures.usage_payload(:weekly_credit_only, now: now, credits: credits), now)
      identity = if credits == :none, do: Repo.update!(Ecto.Changeset.change(identity, metadata: Map.delete(identity.metadata, "quota_account_availability"))), else: identity
      redemption = if opts[:actual_consume], do: identity.metadata["saved_reset_redemption"], else: %{"phase" => "consumed_pending_probe", "status" => "redeeming", "attempt_id" => Ecto.UUID.generate(), "generation" => 1, "started_at" => DateTime.to_iso8601(now), "consumed_at" => DateTime.to_iso8601(now), "deadline_at" => DateTime.to_iso8601(RedemptionLifecycle.deadline_at(now)), "included_window_descriptors" => [%{"window_kind" => "secondary", "window_minutes" => 10_080}], "result" => %{"applied" => true}}
      identity = if opts[:actual_consume], do: identity, else: Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "saved_reset_redemption", redemption)))
      {:ok, probe} = ResetProbe.bind(ResetProbe.new(), setup.assignment.id, identity.id, setup.model.exposed_model_id, request.provider_credits_context.route_class)
      assert {:ok, :claimed} = ProbeLease.claim(identity, redemption["generation"], redemption["attempt_id"], probe)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, reserved} = Accounting.reserve(auth, setup.model, %{"model" => setup.model.exposed_model_id, "input" => "synthetic"}, %{endpoint: @endpoint, transport: request.request_options.transport.transport})
      {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment, %{transport: request.request_options.transport.transport})
      context = %{request.provider_credits_context | reset_probe: probe, redemption_generation: redemption["generation"], redemption_attempt_id: redemption["attempt_id"], request_id: reserved.request.id, attempt_id: attempt.id}
      {%{request | provider_credits_context: context, identity: Repo.reload!(identity), accounting_request: reserved.request, accounting_attempt: attempt, request_options: RequestOptions.put_routing(request.request_options, reset_probe: probe)}, redemption}
    end)
  end

  defp consume_pending!(fixture, setup) do
    now = DateTime.utc_now()
    usage = %{"plan_type" => "synthetic", "rate_limit_reset_credits" => %{"available_count" => 0}}
    inventory = ProviderCreditsFixtures.reset_inventory_payload(1, now: now)
    FakeUpstream.set_mode(fixture.upstream, {:path_json, Map.merge(ProviderCreditsFixtures.usage_routes(usage), %{"/api/codex/rate-limit-reset-credits" => {200, inventory}, "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}}})})

    UnboxedFixture.run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, setup.identity.id)
      bank = %{"status" => "reported", "available_count" => 1, "source" => "codex_usage_api", "path_style" => "codex_api", "observed_at" => DateTime.to_iso8601(now), "usage_path" => "/api/codex/usage", "reason" => nil}
      Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "saved_resets", bank)))
      assert {:ok, %{applied?: true}} = SavedResetRedemption.redeem(setup.assignment)
      redemption = Repo.get!(UpstreamIdentity, setup.identity.id).metadata["saved_reset_redemption"]
      assert redemption["phase"] == "consumed_pending_probe"
      assert redemption["included_window_descriptors"] == [%{"window_kind" => "secondary", "window_minutes" => 10_080}]
    end)

    FakeUpstream.set_mode(fixture.upstream, {:json, 200, %{"id" => "resp_synthetic_probe", "object" => "response", "status" => "completed"}})
  end

  defp recover_included!(fixture, setup, opts \\ []) do
    now = DateTime.utc_now()

    payload =
      ProviderCreditsFixtures.usage_payload(:included, Keyword.merge([now: now, credits: :none], opts))
      |> Map.put("rate_limit_reset_credits", %{"available_count" => 1})

    inventory = ProviderCreditsFixtures.reset_inventory_payload(1, now: now)

    FakeUpstream.set_mode(
      fixture.upstream,
      {:path_json,
       Map.merge(ProviderCreditsFixtures.usage_routes(payload), %{
         "/api/codex/rate-limit-reset-credits" => {200, inventory},
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}}
       })}
    )

    recovered =
      UnboxedFixture.run_unboxed(fn ->
        identity = Repo.get!(UpstreamIdentity, setup.identity.id)
        bank = %{"status" => "reported", "available_count" => 1, "source" => "codex_usage_api", "path_style" => "codex_api", "observed_at" => DateTime.to_iso8601(now), "usage_path" => "/api/codex/usage", "reason" => nil}
        identity = Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "saved_resets", bank)))
        assert {:ok, %{applied?: true}} = SavedResetRedemption.redeem(setup.assignment)
        assert {:ok, fresh} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(identity), setup.assignment)
        assert {:ok, _outcome} = Convergence.converge(fresh)
        Repo.reload!(identity)
      end)

    FakeUpstream.set_mode(fixture.upstream, {:json, 200, %{"id" => "resp_synthetic_recovered", "object" => "response", "status" => "completed"}})
    recovered
  end

  defp execute(request, session), do: ProviderCreditsDispatchSupport.execute(request, session)

  defp selected_context(setup, request, receipt) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    %SelectedCandidateContext{identity: request.identity, assignment: setup.assignment, model: setup.model, endpoint: @endpoint, auth: auth, route_plan: %{affinity: %{enabled?: false}}, route_class: request.provider_credits_context.route_class, request_options: request.request_options, provider_credits_admission: receipt, reserved: %{request: request.accounting_request || %{id: nil, pool_id: setup.assignment.pool_id}}, attempt: request.accounting_attempt, allow_retry?: false, index: 0, retry_count: 0, payload: %{}, started: System.monotonic_time(:millisecond)}
  end

  defp synthetic_upload! do
    root = Path.join(System.tmp_dir!(), "provider-credits-audio-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "audio.wav")
    File.write!(path, "owned synthetic audio fixture")
    %Plug.Upload{path: path, filename: "audio.wav", content_type: "audio/wav"}
  end

  defp hold_inserted_attempt!(_fixture, identity_id, reference) do
    name = String.to_atom("provider_credits_attempt_hold_#{Ecto.UUID.generate()}")
    handler = {__MODULE__, :accounted_attempt, reference}
    gate = %{node: node(), handler: handler, name: name, reference: reference}
    on_exit(fn -> stop_attempt_hold!(gate) end)
    {:ok, keeper} = Agent.start(fn -> nil end, name: name)
    config = %{identity_id: identity_id, notify: self(), reference: reference, keeper: keeper}
    assert :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &ProviderCreditsDispatchSupport.hold_attempt_insert/4, config)
    gate
  end

  defp stop_attempt_hold!(gate) do
    if keeper = Process.whereis(gate.name) do
      if executor = Agent.get(keeper, & &1), do: send(executor, {:provider_credits_attempt_release, gate.reference})
      if gate.node == node(), do: :telemetry.detach(gate.handler), else: :erpc.call(gate.node, :telemetry, :detach, [gate.handler], @budget)
      Agent.stop(keeper)
    end

    :ok
  end

  defp configure_runtime_mode!(setup, mode) do
    TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    UnboxedFixture.run_unboxed(fn ->
      now = DateTime.utc_now()
      Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: Atom.to_string(mode), created_at: now, updated_at: now})
      model = Repo.reload!(setup.model)
      source = %{"slug" => model.exposed_model_id, "upstream_model_id" => model.upstream_model_id, "priority" => 1, "support_verbosity" => false, "experimental_supported_tools" => [], "display_name" => "Synthetic runtime", "description" => "Synthetic runtime", "supported_reasoning_levels" => [%{"effort" => "low", "description" => "low"}, %{"effort" => "medium", "description" => "medium"}, %{"effort" => "high", "description" => "high"}], "default_reasoning_level" => "medium", "shell_type" => "shell_command", "visibility" => "list", "base_instructions" => "", "truncation_policy" => %{"mode" => "bytes", "limit" => 10_000}, "include_skills_usage_instructions" => false, "supports_parallel_tool_calls" => true, "input_modalities" => ["text"], "supported_in_api" => true, "use_responses_lite" => false}
      metadata = Map.put(model.metadata, "source_assignment_models", %{setup.assignment.id => source})
      Repo.update!(Ecto.Changeset.change(model, metadata: metadata))
      identity = Repo.get!(UpstreamIdentity, setup.identity.id)
      Repo.update!(Ecto.Changeset.change(identity, metadata: Map.put(identity.metadata, "supports_compact_responses", true)))
    end)
  end

  defp complete_positive_control!(client, fixture, setup, metadata, :compact, terminal) do
    [item] = terminal["response"]["output"]
    assert item["type"] == "compaction"
    FakeUpstream.set_mode(fixture.upstream, native_completed("resp_synthetic_gate_compact_final", []))
    metadata = %{metadata | "window_id" => Ecto.UUID.generate(), "context_window_id" => Ecto.UUID.generate(), "window_number" => metadata["window_number"] + 1}
    final = hold_socket_generation!(client, native_payload(setup, metadata, SocketSupport.native_text_input("synthetic compact final") ++ [item]))
    assert final.summary.capability_phase == :final
    send(final.sender, {:provider_credits_owner_release, final.reference})
    {client, completed} = receive_client_terminal(final.client)
    assert completed["type"] == "response.completed"
    {client, 3}
  end

  defp complete_positive_control!(client, _fixture, _setup, _metadata, _operation, _terminal), do: {client, 2}

  defp open_owned_socket!(fixture, setup) do
    turn_state = Ecto.UUID.generate()

    session =
      UnboxedFixture.run_unboxed(fn ->
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
        {:ok, session} = Websocket.start_codex_session(auth, %{accepted_turn_state: turn_state, owner_instance_id: Atom.to_string(fixture.peer.node)})
        session
      end)

    on_exit(fn ->
      if fixture.peer.node in Node.list(:connected), do: :erpc.call(fixture.peer.node, ProviderCreditsDispatchSupport, :release_owner_gate, [session.id], @budget)
    end)

    assert {:ok, owner} = :erpc.call(fixture.peer.node, ProviderCreditsDispatchSupport, :start_gated_owner, [session, self()], @budget)
    {_server, port} = SocketSupport.start_public_endpoint_with_server!()
    connect_owned_client!(port, setup, turn_state, owner)
  end

  defp reconnect_owned_socket!(_fixture, setup, client), do: connect_owned_client!(client.port, setup, client.turn_state, client)

  defp connect_owned_client!(port, setup, turn_state, owner) do
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, reference} = SocketSupport.public_websocket_connect!(port, setup, turn_state)
    socket = Mint.HTTP.get_socket(conn)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket_pid = WebsocketCleanupFence.await_new_listener_socket!(before)
    state = WireSupport.socket_connection_state!(socket_pid)
    assert state.codex_session.id == owner.codex_session_id
    assert state.codex_session.owner_instance_id == Atom.to_string(node(owner.owner))
    Map.merge(Map.take(owner, [:owner, :upstream_session, :gate, :codex_session_id]), %{conn: conn, websocket: websocket, reference: reference, socket: socket_pid, port: port, turn_state: turn_state})
  end

  defp send_client_frame(client, payload) do
    {conn, websocket} = SocketSupport.public_websocket_send_text!(client.conn, client.websocket, client.reference, CodexPooler.JSON.encode!(payload))
    %{client | conn: conn, websocket: websocket}
  end

  defp send_socket_turn!(client, payload), do: client |> send_client_frame(payload) |> receive_client_terminal()

  defp receive_client_terminal(client) do
    {conn, websocket, terminal} = receive_terminal(client.conn, client.websocket, client.reference)
    WireSupport.await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0))
    {%{client | conn: conn, websocket: websocket}, terminal}
  end

  defp close_client!(client) do
    Mint.HTTP.close(client.conn)
    WebsocketCleanupFence.await_listener_socket_teardown!(client.socket)
  end

  defp hold_socket_generation!(client, payload) do
    reference = make_ref()
    assert :ok = :erpc.call(node(client.owner), ProviderCreditsDispatchSupport, :arm_owner_gate, [client.gate, reference], @budget)
    client = send_client_frame(client, payload)
    assert_receive {:provider_credits_owner_handoff, ^reference, sender, summary}, @budget
    assert node(sender) == node(client.owner)
    %{client: client, reference: reference, sender: sender, summary: summary}
  end

  defp assert_handoff_contract!(summary, operation, mode) do
    assert summary.request_id != nil
    assert summary.attempt_id != nil
    assert summary.serving_mode == Atom.to_string(mode)
    refute summary.native_replay?

    if operation == :compact do
      assert summary.capability_phase == :compact
      assert summary.delivery_mode in [:collect_compaction, :collect_full_history]
    else
      assert summary.capability_phase == nil
      assert summary.connection_bound?
      assert summary.delivery_mode == :relay
    end
  end

  defp assert_active_anchor!(session_id, response_id) do
    digest = :crypto.hash(:sha256, response_id)
    assert Repo.aggregate(from(alias_record in BridgeSessionAlias, where: alias_record.codex_session_id == ^session_id and alias_record.alias_kind == "previous_response_id" and alias_record.alias_hash == ^digest and alias_record.status == "active"), :count) == 1
  end

  defp assert_unsent_attempt!(attempt_id) do
    attempt = Repo.get!(CodexPooler.Accounting.Attempt, attempt_id)
    assert attempt.status == "failed"
    assert attempt.usage_status == "not_applicable"
    request = Repo.get!(CodexPooler.Accounting.Request, attempt.request_id)
    assert request.usage_status == "not_applicable"
    refute Accounting.reservation_outstanding?(request)
  end

  defp native_metadata do
    %{"session_id" => Ecto.UUID.generate(), "thread_id" => Ecto.UUID.generate(), "turn_id" => Ecto.UUID.generate(), "window_id" => Ecto.UUID.generate(), "context_window_id" => Ecto.UUID.generate(), "window_number" => 1, "request_kind" => "turn"}
  end

  defp native_payload(setup, metadata, input) do
    %{"type" => "response.create", "model" => setup.model.exposed_model_id, "instructions" => "synthetic instructions", "input" => input, "tools" => [%{"type" => "function", "name" => "synthetic_tool", "parameters" => %{"type" => "object", "properties" => %{}}}], "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(metadata)}, "stream" => true, "generate" => true}
  end

  defp controlled_generation_payload(setup, metadata, :anchored, anchor) do
    setup |> native_payload(%{metadata | "turn_id" => Ecto.UUID.generate()}, [%{"type" => "function_call_output", "call_id" => "call_synthetic_anchor", "output" => "synthetic"}]) |> Map.put("previous_response_id", anchor)
  end

  defp controlled_generation_payload(setup, metadata, :steer, anchor) do
    setup |> native_payload(metadata, SocketSupport.native_text_input("synthetic steer")) |> Map.put("previous_response_id", anchor)
  end

  defp controlled_generation_payload(setup, metadata, :compact, anchor) do
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "mid_turn", "strategy" => "memento"}
    metadata = metadata |> Map.put("request_kind", "compaction") |> Map.put("compaction", compaction)
    setup |> native_payload(metadata, [%{"type" => "custom_tool_call_output", "call_id" => "call_synthetic_compact", "output" => "synthetic"}, %{"type" => "compaction_trigger"}]) |> Map.put("previous_response_id", anchor)
  end

  defp synthetic_assistant_item(id), do: %{"type" => "message", "id" => id, "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

  defp native_completed(id, output), do: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => id, "status" => "completed", "output" => output, "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}})])

  defp generation_reply(:compact, id) do
    item = %{"type" => "compaction", "encrypted_content" => "synthetic compact item"}
    FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}), CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}})])
  end

  defp generation_reply(_operation, id), do: native_completed(id, [])

  defp await_processed_frame!(upstream, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @budget

    case Enum.filter(FakeUpstream.requests(upstream), &(get_in(&1, [:json, "type"]) == "response.processed")) do
      [processed] ->
        assert processed.websocket_connection_id == 1

      [] ->
        assert System.monotonic_time(:millisecond) < deadline, "processed control never reached the retained upstream connection"

        receive do
        after
          5 -> await_processed_frame!(upstream, deadline)
        end
    end
  end

  defp persist_runtime_denial!(identity) do
    UnboxedFixture.run_unboxed(fn ->
      denied_at = DateTime.utc_now()
      headers = [{"x-codex-secondary-used-percent", "12"}, {"x-codex-secondary-window-minutes", "10080"}, {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(DateTime.add(denied_at, 7_200, :second)))}, {"x-codex-rate-limit-reached-type", "workspace_member_credits_depleted"}]
      assert {:ok, [_window]} = Windows.upsert_quota_windows_from_codex_headers(identity, headers, denied_at)
      denied_at
    end)
  end

  defp drain_http(response, chunks \\ []) do
    reference = response.body.ref

    receive do
      {^reference, _part} = message ->
        {:ok, parts} = Req.parse_message(response, message)

        body =
          Enum.reduce(parts, chunks, fn
            {:data, data}, chunks -> [data | chunks]
            _part, chunks -> chunks
          end)

        if :done in parts, do: body |> Enum.reverse() |> IO.iodata_to_binary(), else: drain_http(response, body)
    after
      @budget -> flunk("HTTP SSE terminal did not arrive")
    end
  end

  defp receive_terminal(conn, websocket, reference) do
    {conn, websocket, frame} = SocketSupport.public_websocket_receive_text!(conn, websocket, reference)
    decoded = CodexPooler.JSON.decode!(frame)
    if decoded["type"] in ["response.completed", "response.done", "response.incomplete", "error", "response.failed"], do: {conn, websocket, decoded}, else: receive_terminal(conn, websocket, reference)
  end

  defp await_worker(worker) do
    reference = worker.ref
    pid = worker.pid
    monitor = worker.monitor
    assert_receive {:provider_credits_work, ^reference, result}, @budget
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @budget
    result
  end

  defp admission(%Req.Response{} = result), do: Req.Response.get_private(result, :provider_credits_admission)
  defp admission(result), do: result.provider_credits_admission

  defp generation_count(fixture) do
    counts = FakeUpstream.physical_counts(fixture.upstream)
    counts.http_generation + counts.websocket_generation
  end
end
