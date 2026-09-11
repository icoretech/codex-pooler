defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport do
  @moduledoc false

  # Helpers shared by more than one family under
  # test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding/.

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import ExUnit.CaptureLog

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestLogFact
  alias CodexPooler.Accounting.RequestLogs
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.BridgeDemotion
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Transports.WebsocketOwnerPreviousReleaseFixture
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.CodexResponsesSocket

  @sentinel "SECRET_SENTINEL_DO_NOT_STORE_123"
  @blocking_owner_receive_timeout_ms 5_000
  @response_task_stop_timeout_ms 15_000
  @handoff_detection_timeout_ms 15_000
  @epmd_ready_timeout_ms 2_000
  @epmd_ready_poll_ms 10
  @responses_lite_client_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"
  @model_serving_metadata_keys ~w(
    model_serving_mode_configured
    model_serving_mode
    model_serving_mode_source
  )
  @websocket_lifecycle_metadata_keys ~w(
    codex_session_id
    downstream_epoch
    elapsed_ms
    endpoint
    owner_instance_id
    phase
    proxy_instance_id
    reason_class
    request_id
    route_class
    transport
  )
  @websocket_lifecycle_forbidden_terms ~w(
    auth.json
    authorization
    bearer
    cookie
    headers
    idempotency
    payload
    prompt
    upstream_body
    websocket_frame
  )

  defmodule StaleOwnerNodeClient do
    @moduledoc false

    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Persistence.CodexSession
    alias CodexPooler.Repo

    @impl true
    def connected_app_nodes, do: state().nodes

    @impl true
    def app_node?(node), do: node in state().nodes

    @impl true
    def call_owner(_node, _module, _function, [codex_session_id | _args], _timeout) do
      CodexSession
      |> Repo.get!(codex_session_id)
      |> Ecto.Changeset.change(%{owner_lease_token: Ecto.UUID.generate()})
      |> Repo.update!()

      {:error, :owner_unavailable}
    end

    defp state, do: Process.get(__MODULE__, %{nodes: []})
  end

  defmodule TurnBudgetNodeClient do
    @moduledoc false

    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    @key {__MODULE__, :state}

    def configure(node, notify, minimum_timeout_ms) do
      :persistent_term.put(@key, %{
        node: node,
        notify: notify,
        minimum_timeout_ms: minimum_timeout_ms
      })
    end

    def reset, do: :persistent_term.erase(@key)

    @impl true
    def connected_app_nodes, do: [state().node]

    @impl true
    def app_node?(node), do: node == state().node

    @impl true
    def call_owner(_node, module, function, args, timeout) do
      send(state().notify, {:turn_budget_remote_call, function, timeout})

      if function == :remote_submit_request_v1 and timeout <= state().minimum_timeout_ms do
        {:error, :owner_forward_timeout}
      else
        apply(module, function, args)
      end
    end

    defp state, do: :persistent_term.get(@key)
  end

  defmodule ReplayRemoteNodeClient do
    @moduledoc false

    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    @key {__MODULE__, :state}

    def configure(node, notify), do: :persistent_term.put(@key, %{node: node, notify: notify})
    def reset, do: :persistent_term.erase(@key)

    @impl true
    def connected_app_nodes, do: [state().node]

    @impl true
    def app_node?(node), do: node == state().node

    @impl true
    def call_owner(node, module, function, args, _timeout) do
      send(state().notify, {:replay_remote_owner_call, node, function})
      apply(module, function, args)
    end

    defp state, do: :persistent_term.get(@key)
  end

  def strict_owner_response(response_id, connection_ordinal) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: connection_ordinal,
      json: [valid: true, equals: %{"type" => "response.create"}],
      respond:
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{"id" => response_id, "object" => "response"})
        ])
    )
  end

  def websocket_payload(setup, content, extra \\ %{}) do
    websocket_input_payload(
      setup,
      [%{"type" => "message", "role" => "user", "content" => content}],
      extra
    )
  end

  def websocket_input_payload(setup, input, extra \\ %{}) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true,
      "generate" => true
    }
    |> Map.merge(extra)
    |> CodexPooler.JSON.encode!()
  end

  def start_remote_bridge_owner!(auth, session_header, remote_node, persistence_kind \\ :fake) do
    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        session_header: session_header,
        session_header_source: "x-session-id",
        owner_instance_id: Atom.to_string(remote_node)
      })

    persistence =
      case persistence_kind do
        :fake ->
          :erpc.call(remote_node, WebsocketOwnerNodeHarness, :fake_persistence_boundary, [])

        :real ->
          :erpc.call(remote_node, WebsocketOwnerNodeHarness, :real_persistence_boundary, [])
      end

    {:ok, owner_pid} =
      :erpc.call(remote_node, WebsocketOwnerSession, :start_owner, [
        [
          codex_session_id: session.id,
          owner_lease_token: session.owner_lease_token,
          owner_instance_id: session.owner_instance_id,
          owner_renewal_ms: 60_000,
          persistence: persistence
        ]
      ])

    on_exit(fn ->
      if remote_node in Node.list(:connected) and
           :erpc.call(remote_node, Process, :alive?, [owner_pid]) do
        owner_monitor = Process.monitor(owner_pid)
        :erpc.call(remote_node, GenServer, :stop, [owner_pid, :normal, 5_000])

        assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :normal},
                       @handoff_detection_timeout_ms
      end
    end)

    {session, owner_pid}
  end

  def start_bridge_peer!(release, identity, opts \\ [])
      when release in [:current, :previous] and is_struct(identity, UpstreamIdentity) do
    peer_name = String.to_atom("public_owner_#{release}_#{System.unique_integer([:positive])}")

    assert {:ok, peer_pid, peer_node} =
             :peer.start_link(%{
               name: peer_name,
               args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
             })

    Process.unlink(peer_pid)

    on_exit(fn ->
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
      await_peer_down!(peer_name, peer_node)
    end)

    assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    signing_config =
      :codex_pooler
      |> Application.fetch_env!(CodexPoolerWeb.Endpoint)
      |> Keyword.take([:secret_key_base])

    assert :ok =
             :erpc.call(peer_node, Application, :put_env, [
               :codex_pooler,
               CodexPoolerWeb.Endpoint,
               signing_config
             ])

    assert {:ok, runtime_pid} =
             :erpc.call(peer_node, WebsocketOwnerNodeHarness, :start_owner_runtime, [])

    assert node(runtime_pid) == peer_node

    if Keyword.get(opts, :repo) == :real do
      repo_config =
        :codex_pooler
        |> Application.fetch_env!(Repo)
        |> Keyword.merge(pool: DBConnection.ConnectionPool, pool_size: 2)

      assert is_pid(:erpc.call(peer_node, WebsocketOwnerNodeHarness, :start_repo, [repo_config]))

      upstream_config = Application.get_env(:codex_pooler, Upstreams, [])

      assert :ok =
               :erpc.call(peer_node, Application, :put_env, [
                 :codex_pooler,
                 Upstreams,
                 upstream_config
               ])
    end

    on_exit(fn ->
      if remote_node_connected?(peer_node) and
           :erpc.call(peer_node, Process, :alive?, [runtime_pid]) do
        send(runtime_pid, :stop)
      end
    end)

    case release do
      :current ->
        assert {:module, CodexPooler.Upstreams} =
                 WebsocketOwnerPreviousReleaseFixture.load_synthetic_identity_lookup(
                   peer_node,
                   identity.id
                 )

        trace_remote_v1_calls!(peer_node)

      :previous ->
        assert {:module, WebsocketOwnerForwarder} =
                 WebsocketOwnerPreviousReleaseFixture.load_pre_v1_bridge_forwarder(peer_node)

        refute :erpc.call(peer_node, :erlang, :function_exported, [
                 WebsocketOwnerForwarder,
                 :remote_submit_request_v1,
                 3
               ])
    end

    peer_node
  end

  defp trace_remote_v1_calls!(peer_node) do
    assert {:ok, tracer} =
             :erpc.call(
               peer_node,
               WebsocketOwnerPreviousReleaseFixture,
               :start_forwarder_v1_trace,
               [self()]
             )

    assert node(tracer) == peer_node
  end

  def assert_forwarding_cardinality!(request, codex_session_id, status) do
    {request, attempt, turn, settlement, fact} =
      await_forwarding_persistence!(request.id, codex_session_id, status)

    assert Repo.aggregate(from(r in Request, where: r.id == ^request.id), :count) == 1
    assert attempt.status == status
    assert settlement.attempt_id == attempt.id
    assert turn.status == status
    assert turn.final_attempt_id == attempt.id
    assert fact.latest_attempt_id == attempt.id
    assert fact.latest_attempt_number == 1
    assert fact.latest_attempt_status == status
    assert fact.latest_settlement_entry_id == settlement.id
    assert request.retry_count == 0
    assert attempt.attempt_number == 1

    assert Repo.aggregate(from(f in RequestLogFact, where: f.request_id == ^request.id), :count) ==
             1

    {request, attempt, turn, settlement, fact}
  end

  def await_forwarding_persistence!(request_id, codex_session_id, status, attempts \\ 1_000)

  def await_forwarding_persistence!(_request_id, _codex_session_id, _status, 0) do
    flunk("expected finalized forwarding persistence")
  end

  def await_forwarding_persistence!(request_id, codex_session_id, status, attempts) do
    request = Repo.get(Request, request_id)
    request_attempts = Repo.all(from(a in Attempt, where: a.request_id == ^request_id))

    settlements =
      Repo.all(
        from(e in LedgerEntry,
          where: e.request_id == ^request_id and e.entry_kind == "settlement"
        )
      )

    turns = Repo.all(forwarding_turn_query(request_id, codex_session_id))
    fact = Repo.get(RequestLogFact, request_id)

    case {request, request_attempts, turns, settlements, fact} do
      {%Request{status: ^status, completed_at: %DateTime{}} = request,
       [%Attempt{status: ^status, completed_at: %DateTime{}} = attempt],
       [%CodexTurn{status: ^status, completed_at: %DateTime{}} = turn],
       [%LedgerEntry{} = settlement], %RequestLogFact{} = fact}
      when settlement.attempt_id == attempt.id and turn.final_attempt_id == attempt.id and
             fact.latest_attempt_id == attempt.id and
             fact.latest_settlement_entry_id == settlement.id ->
        {request, attempt, turn, settlement, fact}

      _not_finalized ->
        yield_once({:await_forwarding_persistence, request_id, attempts})
        await_forwarding_persistence!(request_id, codex_session_id, status, attempts - 1)
    end
  end

  defp forwarding_turn_query(request_id, nil),
    do: from(t in CodexTurn, where: t.request_id == ^request_id)

  defp forwarding_turn_query(request_id, codex_session_id),
    do:
      from(t in CodexTurn,
        where: t.request_id == ^request_id and t.codex_session_id == ^codex_session_id
      )

  def assert_no_markers_persisted!(rows, pool_id, markers) do
    {request, _attempt, turn, _settlement, _fact} = rows

    session_ids =
      [turn.codex_session_id]
      |> Enum.reject(&is_nil/1)

    persisted = %{
      request_rows: rows,
      ledger_entries: Repo.all(from(e in LedgerEntry, where: e.request_id == ^request.id)),
      sessions: Repo.all(from(s in CodexSession, where: s.id in ^session_ids)),
      owner_leases:
        Repo.all(from(l in BridgeOwnerLease, where: l.codex_session_id in ^session_ids)),
      session_aliases:
        Repo.all(from(a in BridgeSessionAlias, where: a.codex_session_id in ^session_ids)),
      demotions: Repo.all(from(d in BridgeDemotion, where: d.pool_id == ^pool_id)),
      circuits: Repo.all(from(c in RoutingCircuitState, where: c.pool_id == ^pool_id)),
      request_log: Accounting.list_request_logs(pool_id, filters: %{request_id: request.id})
    }

    persisted = inspect(persisted)
    Enum.each(markers, &refute(persisted =~ &1))
  end

  defp ensure_epmd_started! do
    case :erl_epmd.names() do
      {:ok, _names} ->
        :ok

      {:error, _reason} ->
        assert {_output, 0} = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
        await_epmd!(System.monotonic_time(:millisecond) + @epmd_ready_timeout_ms)
    end
  end

  defp await_epmd!(deadline) do
    case :erl_epmd.names() do
      {:ok, _names} ->
        :ok

      {:error, _reason} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            @epmd_ready_poll_ms -> await_epmd!(deadline)
          end
        else
          flunk("EPMD did not become ready: #{inspect(error)}")
        end
    end
  end

  def ensure_test_distribution_started! do
    ensure_epmd_started!()
    start_test_distribution!(node())
  end

  defp start_test_distribution!(:nonode@nohost) do
    previous_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
    Application.put_env(:kernel, :prevent_overlapping_partitions, false)
    node_name = String.to_atom("controller_owner_test_#{System.unique_integer([:positive])}")
    assert {:ok, net_kernel_pid} = :net_kernel.start([node_name, :shortnames])

    on_exit(fn ->
      try do
        monitor = Process.monitor(net_kernel_pid)
        deadline = System.monotonic_time(:millisecond) + @handoff_detection_timeout_ms
        assert :ok = :net_kernel.stop()

        assert_receive {:DOWN, ^monitor, :process, ^net_kernel_pid, _reason},
                       @handoff_detection_timeout_ms

        await_local_node_stopped!(deadline)
      after
        case previous_partition_guard do
          {:ok, value} -> Application.put_env(:kernel, :prevent_overlapping_partitions, value)
          :error -> Application.delete_env(:kernel, :prevent_overlapping_partitions)
        end
      end
    end)
  end

  defp start_test_distribution!(_distributed_node), do: :ok

  defp await_local_node_stopped!(deadline) do
    if node() == :nonode@nohost do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0, "local distribution did not stop"

      receive do
      after
        min(@epmd_ready_poll_ms, remaining) -> await_local_node_stopped!(deadline)
      end
    end
  end

  defp remote_node_connected?(peer_node), do: peer_node in Node.list(:connected)

  defp await_peer_down!(peer_name, peer_node),
    do:
      await_peer_down!(
        peer_name,
        peer_node,
        System.monotonic_time(:millisecond) + @handoff_detection_timeout_ms
      )

  defp await_peer_down!(peer_name, peer_node, deadline) do
    {:ok, names} = :erl_epmd.names()

    if peer_node not in Node.list(:connected) and
         not Enum.any?(names, fn {name, _port} -> name == Atom.to_charlist(peer_name) end) do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0, "peer did not stop"

      receive do
      after
        min(@epmd_ready_poll_ms, remaining) -> await_peer_down!(peer_name, peer_node, deadline)
      end
    end
  end

  def receive_receiver_delivery_gap_result(task_pid, state) do
    receive do
      {:websocket_response_activity, ^task_pid, _activity_token} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        receive_receiver_delivery_gap_result(task_pid, state)

      {:codex_response_done, ^task_pid, _result} = message ->
        assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
        state
    after
      @handoff_detection_timeout_ms ->
        flunk("expected response-task result handoff")
    end
  end

  def maybe_proxy_owner_state(state, :direct), do: state

  def maybe_proxy_owner_state(state, :proxy) do
    remote_node = :"codex_pooler@continuation-owner.example"

    remote_owner_state(
      state,
      remote_node,
      WebsocketOwnerNodeHarness.node_client_opts([remote_node],
        calls: %{remote_node => :success}
      )
    )
  end

  def native_owner_retry_terminal do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 400,
      "error" => %{
        "type" => "invalid_request_error",
        "code" => "previous_response_not_found",
        "message" => "Previous response was not found. Retrying the full request."
      }
    })
  end

  def model_serving_owner_payload(setup, label, spoofed_lite_value) do
    websocket_payload(setup, "synthetic owner mode #{label}", %{
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "medium", "context" => "current_turn"},
      "client_metadata" => %{
        @responses_lite_client_metadata_key => spoofed_lite_value,
        "model_serving_mode" => "unknown"
      }
    })
  end

  def remote_owner_state(state, remote_node, node_opts) do
    %{
      state
      | codex_session: %{
          state.codex_session
          | owner_instance_id: Atom.to_string(remote_node)
        },
        opts: put_owner_node_opts(state.opts, node_opts)
    }
  end

  def owner_response_options(state, node_opts) do
    Gateway.websocket_owner_response_options(
      put_owner_node_opts(state.opts, node_opts),
      state.codex_session,
      state.websocket_owner_lease_token,
      state.websocket_owner_downstream
    )
  end

  defp put_owner_node_opts(%RequestOptions{} = opts, node_opts) do
    RequestOptions.put_transport(opts, websocket_owner_forwarder_opts: node_opts)
  end

  defp put_owner_node_opts(opts, node_opts) when is_map(opts) do
    Map.put(opts, :websocket_owner_forwarder_opts, node_opts)
  end

  def owner_response_id(frame) do
    decoded = CodexPooler.JSON.decode!(frame)
    decoded["id"] || get_in(decoded, ["response", "id"])
  end

  def assert_remote_submit_request_v1!(state, remote_node, mode \\ nil, timeout \\ 100) do
    codex_session_id = state.codex_session.id
    downstream = state.websocket_owner_downstream

    assert_receive {:websocket_owner_harness_node_call,
                    %{
                      node: ^remote_node,
                      function: :remote_submit_request_v1,
                      arity: 3,
                      codex_session_id: ^codex_session_id,
                      downstream: ^downstream
                    } = call},
                   timeout

    if mode, do: assert(call.mode == mode)

    assert_receive {:websocket_owner_harness_request,
                    %WebsocketOwnerRequest{version: 1} = owner_request},
                   timeout

    assert :ok = WebsocketOwnerRequest.validate(owner_request)
    refute contains_function?(owner_request)
    owner_request
  end

  def contains_function?(value) when is_function(value), do: true

  def contains_function?(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> contains_function?()
  end

  def contains_function?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested_value} ->
      contains_function?(key) or contains_function?(nested_value)
    end)
  end

  def contains_function?(value) when is_list(value), do: Enum.any?(value, &contains_function?/1)

  def contains_function?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.any?(&contains_function?/1)
  end

  def contains_function?(_value), do: false

  def assert_canonical_lite_owner_request!(captured) do
    assert captured.method == "WEBSOCKET"

    assert get_in(captured.json, ["client_metadata", @responses_lite_client_metadata_key]) ==
             "true"

    assert captured.json["parallel_tool_calls"] == false
    assert get_in(captured.json, ["reasoning", "context"]) == "all_turns"
  end

  def assert_canonical_full_owner_request!(captured) do
    assert captured.method == "WEBSOCKET"

    refute get_in(captured.json, ["client_metadata", @responses_lite_client_metadata_key])
    assert captured.json["parallel_tool_calls"] == true
    assert get_in(captured.json, ["reasoning", "context"]) == "current_turn"
  end

  def assert_owner_mode_accounting!(request, mode, status, remote_node) do
    expected = %{
      "model_serving_mode_configured" => mode,
      "model_serving_mode" => mode,
      "model_serving_mode_source" => "override"
    }

    assert request.status == status
    assert request.transport == "websocket"
    assert Map.take(request.request_metadata["routing"], @model_serving_metadata_keys) == expected

    owner_metadata = request.request_metadata["websocket_owner_forwarding"]
    assert owner_metadata["enabled"] == true
    assert owner_metadata["owner_instance_id"] == Atom.to_string(remote_node)
    assert owner_metadata["proxy_instance_id"] == Atom.to_string(node())

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == status
    assert attempt.transport == "websocket"

    assert Map.take(attempt.response_metadata["routing"], @model_serving_metadata_keys) ==
             expected
  end

  def ensure_previous_response_alias!(
        %CodexSession{} = session,
        %APIKey{} = api_key,
        response_id
      ) do
    alias_hash = :crypto.hash(:sha256, response_id)

    case Repo.get_by(BridgeSessionAlias,
           pool_id: session.pool_id,
           api_key_id: api_key.id,
           alias_kind: "previous_response_id",
           alias_hash: alias_hash,
           status: "active"
         ) do
      %BridgeSessionAlias{} = alias_record ->
        alias_record

      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %BridgeSessionAlias{}
        |> BridgeSessionAlias.changeset(%{
          codex_session_id: session.id,
          pool_id: session.pool_id,
          api_key_id: api_key.id,
          alias_kind: "previous_response_id",
          alias_hash: alias_hash,
          alias_preview: "synthetic-prev",
          status: "active",
          expires_at: DateTime.add(now, 300, :second),
          last_seen_at: now,
          metadata: %{},
          created_at: now,
          updated_at: now
        })
        |> Repo.insert!()
    end
  end

  def capture_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  def capture_websocket_lifecycle_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(
        [
          level: :info,
          format: "$metadata$message\n",
          metadata: @websocket_lifecycle_metadata_keys,
          colors: [enabled: false]
        ],
        fun
      )
    after
      Logger.configure(level: previous_level)
    end
  end

  def owner_socket(auth, request_id, turn_state, extra_opts \\ []) do
    CodexResponsesSocket.init(%{
      auth: auth,
      opts:
        Map.merge(
          %{
            request_id: request_id,
            accepted_turn_state: turn_state,
            client_ip: "127.0.0.1"
          },
          Map.new(extra_opts)
        )
    })
  end

  def socket_test_task do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  def stop_socket_test_task(task_pid) when is_pid(task_pid) do
    if Process.alive?(task_pid), do: send(task_pid, :stop)
  end

  def receive_owner_socket_push(state) do
    receive do
      {:websocket_owner_cleanup_witness, _, _, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:codex_response_done, _, _} = message ->
        handle_owner_socket_push_message(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_owner_socket_push_message(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected owner websocket response frame")
    end
  end

  def receive_native_collect_socket_push(state) do
    receive do
      {:websocket_owner_cleanup_witness, _, _, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)

      # After an upstream transport failure the owner retains its result until
      # the socket acks this probe (or 5 s elapse); route it through the socket
      # like the real connection does instead of letting the owner time out.
      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:codex_response_chunk, _task_pid, _frame} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:codex_response_done, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_native_collect_socket_push_message(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected collected native websocket response frame")
    end
  end

  defp handle_native_collect_socket_push_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:push, {:text, frame}, state} = result ->
        if StreamProtocol.internal_control_event?(frame) do
          receive_native_collect_socket_push(state)
        else
          result
        end

      {:ok, state} ->
        receive_native_collect_socket_push(state)
    end
  end

  defp handle_owner_socket_push_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:push, {:text, frame}, state} = result ->
        if StreamProtocol.internal_control_event?(frame) do
          receive_owner_socket_push(state)
        else
          result
        end

      {:ok, state} ->
        receive_owner_socket_push(state)
    end
  end

  def receive_owner_socket_raw_push(state) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:codex_response_done, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_owner_socket_raw_push_message(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected owner websocket response frame")
    end
  end

  defp handle_owner_socket_raw_push_message(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:push, {:text, _frame}, _state} = result -> result
      {:ok, state} -> receive_owner_socket_raw_push(state)
    end
  end

  def receive_owner_socket_complete(state) do
    receive do
      {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message ->
        handle_owner_socket_complete_message(message, state)

      {:websocket_owner_frame, _correlation_id, _epoch, _payload} = message ->
        handle_owner_socket_complete_message(message, state)

      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message ->
        handle_owner_socket_complete_control(message, state)

      {:websocket_response_activity, _, _} = message ->
        handle_owner_socket_complete_control(message, state)

      {:codex_response_done, _, _} = message ->
        handle_owner_socket_complete_control(message, state)

      {:websocket_response_delivery_complete, _, _} = message ->
        handle_owner_socket_complete_control(message, state)
    after
      @handoff_detection_timeout_ms -> flunk("expected owner websocket completion frame")
    end
  end

  defp handle_owner_socket_complete_message(message, state) do
    accepted_completion? =
      Adapter.accept_downstream_message(message, state) == {:ok, :complete}

    result = CodexResponsesSocket.handle_info(message, state)

    case result do
      {:ok, next_state} ->
        if accepted_completion? or owner_completion_transition?(message, state, next_state) do
          {:ok, next_state}
        else
          receive_owner_socket_complete(next_state)
        end

      {:push, _frame, state} ->
        receive_owner_socket_complete(state)

      {:stop, _reason, _detail, _state} = stop ->
        stop

      {:stop, _reason, _detail, _frames, _state} = stop ->
        stop
    end
  end

  defp owner_completion_transition?(
         {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, :complete},
         previous_state,
         next_state
       ) do
    owner_completion_state_transition?(previous_state, next_state)
  end

  defp owner_completion_transition?(
         {:websocket_owner_frame, _correlation_id, _epoch, :complete},
         previous_state,
         next_state
       ) do
    owner_completion_state_transition?(previous_state, next_state)
  end

  defp owner_completion_transition?(_message, _previous_state, _next_state), do: false

  defp owner_completion_state_transition?(previous_state, next_state) do
    (not Map.get(previous_state, :native_owner_terminal_delivered?, false) and
       Map.get(next_state, :native_owner_terminal_delivered?, false)) or
      (not Map.get(previous_state, :public_turn_owner_complete?, false) and
         Map.get(next_state, :public_turn_owner_complete?, false)) or
      (Map.get(previous_state, :websocket_owner_active_turn_reconnect?, false) and
         not Map.get(next_state, :websocket_owner_active_turn_reconnect?, false))
  end

  defp handle_owner_socket_complete_control(message, state) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:ok, state} -> receive_owner_socket_complete(state)
      {:push, _frame, state} -> receive_owner_socket_complete(state)
      {:stop, _reason, _detail, _state} = stop -> stop
      {:stop, _reason, _detail, _frames, _state} = stop -> stop
    end
  end

  def flush_socket_done(state) do
    receive do
      {:codex_response_done, pid, result} ->
        CodexResponsesSocket.handle_info({:codex_response_done, pid, result}, state)
    after
      100 -> :ok
    end
  end

  # Crash tests in this file run the sandbox in auto mode and commit their
  # rows, so every table assertion is scoped to the test's own Pool.
  def pool_attempts(pool_id) do
    Repo.all(
      from(a in Attempt,
        join: r in Request,
        on: r.id == a.request_id,
        where: r.pool_id == ^pool_id,
        order_by: [asc: a.attempt_number]
      )
    )
  end

  def pool_ledger_entries(pool_id) do
    Repo.all(
      from(l in LedgerEntry,
        join: r in Request,
        on: r.id == l.request_id,
        where: r.pool_id == ^pool_id
      )
    )
  end

  def request_logs(pool_id) do
    Repo.all(
      from(r in Request,
        where: r.pool_id == ^pool_id,
        order_by: [asc: r.admitted_at]
      )
    )
  end

  def assert_native_turn_correlation!(correlation_id) when is_binary(correlation_id) do
    assert correlation_id =~ ~r/\Acodex-turn:[A-Za-z0-9_-]{43}\z/
  end

  def assert_websocket_lifecycle_line!(logs, message, required_keys, optional_keys) do
    lifecycle_lines =
      logs
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, message))

    assert [line] = lifecycle_lines

    metadata_text =
      line
      |> String.replace_prefix(message, "")
      |> String.trim_leading()

    metadata_keys =
      metadata_text
      |> String.split(" ", trim: true)
      |> Enum.map(fn token -> token |> String.split("=", parts: 2) |> hd() end)

    assert Enum.all?(metadata_keys, &(&1 in @websocket_lifecycle_metadata_keys))
    assert Enum.all?(required_keys, &(&1 in metadata_keys))
    assert Enum.all?(metadata_keys, &(&1 in (required_keys ++ optional_keys)))
    assert_no_websocket_lifecycle_leaks!(logs)

    line
  end

  def assert_no_websocket_lifecycle_leaks!(logs) do
    downcased_logs = String.downcase(logs)

    for forbidden_term <- @websocket_lifecycle_forbidden_terms do
      refute downcased_logs =~ forbidden_term
    end

    refute downcased_logs =~ @sentinel
  end

  # `active_socket_turn_fixture/3` parks the forwarded response task inside
  # `WebsocketOwnerSession.submit_request/4` (a `:infinity` call) until `on_exit`
  # releases the fake upstream. Once the owner-lifecycle outcome has been
  # asserted that task is an orphan, and `CodexResponsesSocket.terminate/2`
  # would otherwise burn its full post-cleanup drain budget (15 s for
  # owner-forwarded state, 5 s otherwise) before killing it itself. Stop it
  # here so terminate observes an immediate `:DOWN`; the pid stays in
  # `state.tasks`, so cleanup still treats the socket as holding an active turn.
  def stop_parked_response_tasks!(state) do
    state
    |> Map.get(:tasks, MapSet.new())
    |> Enum.each(fn task_pid ->
      monitor = Process.monitor(task_pid)
      Process.exit(task_pid, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^task_pid, _reason},
                     @handoff_detection_timeout_ms
    end)

    state
  end

  def suspend_cleanup_task!(state) do
    task = state.websocket_owner_cleanup_task
    test_process = self()
    barrier = make_ref()

    holder =
      spawn(fn ->
        monitor = Process.monitor(test_process)
        true = :erlang.suspend_process(task)
        send(test_process, {:cleanup_task_suspended, barrier})

        receive do
          {:release_cleanup_task, ^barrier} -> :ok
          {:DOWN, ^monitor, :process, ^test_process, _reason} -> :ok
        end
      end)

    assert_receive {:cleanup_task_suspended, ^barrier}, @handoff_detection_timeout_ms
    on_exit(fn -> send(holder, {:release_cleanup_task, barrier}) end)

    fn ->
      monitor = Process.monitor(holder)
      send(holder, {:release_cleanup_task, barrier})
      assert_receive {:DOWN, ^monitor, :process, ^holder, _reason}, @handoff_detection_timeout_ms
    end
  end

  def active_socket_turn_fixture(setup, upstream, state) do
    release_ref = make_ref()

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.delayed_terminal_sse_stream(
        [],
        %{"type" => "response.completed", "response" => %{"status" => "completed"}},
        notify: self(),
        release_ref: release_ref
      )
    )

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {websocket_payload(setup, "owner lifecycle"), [opcode: :text]},
               state
             )

    assert_receive {:websocket_owner_cleanup_witness, _correlation, _epoch, _task, witness} =
                     message,
                   @handoff_detection_timeout_ms

    assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
    assert state.websocket_owner_cleanup_witness == witness

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, barrier, ^release_ref},
                   @handoff_detection_timeout_ms

    on_exit(fn -> send(barrier, {:fake_upstream_release_timeout, release_ref}) end)
    request = Repo.get!(Request, witness.request_id)
    attempt = Repo.get!(Attempt, witness.attempt_id)
    turn = Repo.get_by!(CodexTurn, request_id: request.id)
    assert request.status == "in_progress"
    assert attempt.status == "in_progress"
    assert turn.status == "in_progress"
    %{request: request, attempt: attempt, turn: turn, state: state}
  end

  def assert_owner_interruption_state!(%{
        request: request,
        attempt: attempt,
        turn: turn,
        session: session,
        error_code: error_code
      }) do
    reloaded_request = Repo.get!(Request, request.id)
    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    reloaded_turn = Repo.get!(CodexTurn, turn.id)
    reloaded_session = Repo.get!(CodexSession, session.id)

    assert reloaded_request.status == "failed"
    assert reloaded_request.response_status_code == 499
    assert reloaded_request.last_error_code == error_code
    assert reloaded_attempt.status == "failed"
    assert reloaded_attempt.upstream_status_code == 499
    assert reloaded_attempt.network_error_code == error_code
    assert reloaded_turn.status == "interrupted"
    assert reloaded_turn.error_code == error_code
    assert reloaded_turn.final_attempt_id == attempt.id
    assert reloaded_session.status == "interrupted"
  end

  def assert_owner_success_preserved!(%{request: request, attempt: attempt, turn: turn}) do
    reloaded_request = Repo.get!(Request, request.id)
    reloaded_attempt = Repo.get!(Attempt, attempt.id)
    reloaded_turn = Repo.get!(CodexTurn, turn.id)

    assert reloaded_request.status == "succeeded"
    assert reloaded_request.response_status_code == 200
    assert is_nil(reloaded_request.last_error_code)
    assert reloaded_attempt.status == "succeeded"
    assert reloaded_attempt.upstream_status_code == 200
    assert is_nil(reloaded_attempt.network_error_code)
    assert reloaded_turn.status == "succeeded"
    assert is_nil(reloaded_turn.error_code)
    assert reloaded_turn.final_attempt_id == attempt.id
  end

  def assert_no_leak_in_persistence!(pool_id) do
    assert_no_leak!("persistence rows", persistence_excerpt(pool_id))
  end

  def assert_owner_websocket_values_not_persisted!(setup, forbidden_values, logs) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    request_ids = Enum.map(requests, & &1.id)
    attempts = Repo.all(from(a in Attempt, where: a.request_id in ^request_ids))
    sessions = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    session_ids = Enum.map(sessions, & &1.id)
    turns = Repo.all(from(t in CodexTurn, where: t.codex_session_id in ^session_ids))
    audit_events = Repo.all(from(e in AuditEvent))
    request_logs = RequestLogs.list(setup.pool.id, limit: 10)

    durable_text =
      inspect({requests, attempts, sessions, turns, audit_events, request_logs.items})

    for value <- forbidden_values do
      refute durable_text =~ value
      refute logs =~ value
    end
  end

  def refute_raw_turn_state_session_key!(pool_id, turn_state) do
    refute Repo.exists?(
             from session in CodexSession,
               where:
                 session.pool_id == ^pool_id and
                   fragment("lower(?)", session.session_key) == ^String.downcase(turn_state)
           )
  end

  def turn_state_session_key(turn_state) do
    "x-codex-turn-state:" <>
      (:crypto.hash(:sha256, String.trim(turn_state)) |> Base.encode16(case: :lower))
  end

  defp persistence_excerpt(pool_id) do
    requests =
      Repo.all(
        from r in Request,
          where: r.pool_id == ^pool_id,
          order_by: [asc: r.admitted_at],
          select: %{
            endpoint: r.endpoint,
            transport: r.transport,
            status: r.status,
            request_metadata: r.request_metadata,
            last_error_code: r.last_error_code,
            response_status_code: r.response_status_code
          }
      )

    request_ids = Repo.all(from r in Request, where: r.pool_id == ^pool_id, select: r.id)
    session_ids = Repo.all(from s in CodexSession, where: s.pool_id == ^pool_id, select: s.id)

    %{
      requests: requests,
      attempts:
        Repo.all(
          from a in Attempt,
            where: a.request_id in ^request_ids,
            order_by: [asc: a.attempt_number],
            select: %{
              transport: a.transport,
              status: a.status,
              network_error_code: a.network_error_code,
              error_message: a.error_message,
              response_metadata: a.response_metadata
            }
        ),
      codex_sessions:
        Repo.all(
          from s in CodexSession,
            where: s.pool_id == ^pool_id,
            select: %{
              session_key: s.session_key,
              conversation_key: s.conversation_key,
              status: s.status,
              owner_instance_id: s.owner_instance_id
            }
        ),
      codex_turns:
        Repo.all(
          from t in CodexTurn,
            where: t.codex_session_id in ^session_ids,
            select: %{
              transport_kind: t.transport_kind,
              status: t.status,
              error_code: t.error_code
            }
        ),
      bridge_owner_leases:
        Repo.all(
          from l in BridgeOwnerLease,
            where: l.pool_id == ^pool_id,
            select: %{
              owner_instance_id: l.owner_instance_id,
              status: l.status,
              metadata: l.metadata
            }
        ),
      bridge_session_aliases:
        Repo.all(
          from a in BridgeSessionAlias,
            where: a.pool_id == ^pool_id,
            select: %{
              alias_kind: a.alias_kind,
              alias_preview: a.alias_preview,
              status: a.status,
              metadata: a.metadata
            }
        )
    }
  end

  def assert_no_leak!(label, value) do
    if value |> inspect(limit: 80, printable_limit: 4_000) |> String.contains?(@sentinel) do
      flunk("sentinel leaked through #{label}")
    end
  end

  def downstream_target(correlation_id),
    do: %{pid: self(), epoch: 1, correlation_id: correlation_id}

  def blocking_owner_upstream_boundary(test_pid, release_ref) do
    %{
      start: fn -> Agent.start_link(fn -> %{received?: false, closed?: false} end) end,
      send: fn upstream_pid, _request, _writer ->
        Agent.update(upstream_pid, fn state -> %{state | received?: true} end)
        send(test_pid, {:blocking_owner_upstream_received, self(), release_ref})

        receive do
          {:blocking_owner_upstream_release, ^release_ref} -> :ok
        after
          5_000 -> exit(:blocking_owner_upstream_timeout)
        end
      end,
      close: fn upstream_pid ->
        Agent.update(upstream_pid, fn state -> %{state | closed?: true} end)
        Agent.stop(upstream_pid)
      end
    }
  end

  def assert_blocking_owner_upstream_received!(release_ref) do
    receive do
      {:blocking_owner_upstream_received, owner_worker_pid, ^release_ref} -> owner_worker_pid
    after
      @blocking_owner_receive_timeout_ms ->
        flunk("expected blocking owner upstream to receive the websocket request")
    end
  end

  def assert_response_task_stopped!(state) do
    [response_task_pid] = MapSet.to_list(state.tasks)
    assert_response_task_stopped!(state, response_task_pid)
  end

  def assert_response_task_stopped!(_state, response_task_pid) do
    monitor = Process.monitor(response_task_pid)

    assert_receive {:DOWN, ^monitor, :process, ^response_task_pid, _reason},
                   @response_task_stop_timeout_ms
  end

  def acknowledge_response_task_delivery_if_pending(state, task_pid) do
    case Map.fetch(state.response_task_activities, task_pid) do
      {:ok, token} ->
        CodexResponsesSocket.handle_info(
          {:websocket_response_delivery_complete, task_pid, token},
          state
        )

      :error ->
        if MapSet.member?(state.tasks, task_pid) do
          receive do
            {:websocket_response_activity, ^task_pid, _token} = message ->
              assert {:ok, state} = CodexResponsesSocket.handle_info(message, state)
              acknowledge_response_task_delivery_if_pending(state, task_pid)
          after
            @response_task_stop_timeout_ms ->
              flunk("expected response task activity registration")
          end
        else
          {:ok, state}
        end
    end
  end

  def active_owner_lease(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1
    )
  end

  def released_owner_lease(session_id, lease_token) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^session_id and lease.lease_token == ^lease_token and
            lease.status == "released",
        limit: 1
    )
  end

  def await_upstream_requests(upstream, expected_count, attempts \\ 100)

  def await_upstream_requests(upstream, expected_count, attempts) when attempts > 0 do
    requests = FakeUpstream.requests(upstream)

    if length(requests) == expected_count do
      requests
    else
      yield_once({:await_upstream_requests, expected_count, attempts})
      await_upstream_requests(upstream, expected_count, attempts - 1)
    end
  end

  def await_upstream_requests(upstream, _expected_count, 0), do: FakeUpstream.requests(upstream)

  def yield_once(message) do
    send(self(), message)

    receive do
      ^message -> :ok
    end
  end

  def with_proxy_websocket_bulkhead(queue_limit, queue_timeout_ms, fun)
      when is_integer(queue_limit) and queue_limit >= 0 and is_integer(queue_timeout_ms) and
             queue_timeout_ms > 0 and is_function(fun, 0) do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        bulkheads:
          Map.new(Admission.route_classes(), fn route_class ->
            {route_class, %{max_concurrency: 4, queue_limit: 0, queue_timeout_ms: 1_000}}
          end)
          |> Map.put("proxy_websocket", %{
            max_concurrency: 1,
            queue_limit: queue_limit,
            queue_timeout_ms: queue_timeout_ms
          })
      }
    )

    Admission.reset_for_test()

    try do
      fun.()
    after
      Admission.reset_for_test()

      case previous_settings do
        nil -> Application.delete_env(:codex_pooler, OperationalSettings)
        value -> Application.put_env(:codex_pooler, OperationalSettings, value)
      end
    end
  end

  def cleanup_local_owner_sessions do
    logs =
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn codex_session_id ->
          await_owner_cleanup!(codex_session_id)
        end)
      end)

    assert_no_leak!("owner cleanup logs", logs)
  end

  def await_owner_cleanup!(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner_pid} ->
        monitor = Process.monitor(owner_pid)

        try do
          GenServer.stop(owner_pid, :shutdown, @handoff_detection_timeout_ms)
        catch
          :exit, {:noproc, _details} -> :ok
          :exit, {:normal, _details} -> :ok
        end

        assert_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason},
                       @handoff_detection_timeout_ms

      {:error, :owner_unavailable} ->
        :ok
    end

    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(codex_session_id)
  end
end
