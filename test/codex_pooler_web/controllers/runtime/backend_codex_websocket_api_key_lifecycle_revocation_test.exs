defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyLifecycleRevocationTest do
  @moduledoc """
  Real-path coverage for an already-open Responses websocket whose API key stops
  being usable from another application node without a pause or revoke: the key
  is deleted, it expires, it moves to another Pool, or its Pool is disabled or
  archived and deleted.

  The change runs on a peer node that shares only PostgreSQL with this node, so
  the prompt event reaches the socket through the PostgreSQL relay, and
  suspending that relay leaves the durable fence as the only thing that can
  refuse the next frame.
  """

  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import CodexPooler.AccountsFixtures, only: [committed_bootstrap_owner_fixture!: 0]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Events.PostgresBridge
  alias CodexPooler.FakeUpstream
  alias CodexPooler.PeerRegistry
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, UpstreamIdentity}
  alias Ecto.Adapters.SQL.Sandbox

  @peer_module CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyLifecyclePeer
  @peer_pubsub_adapter CodexPoolerWeb.Runtime.BackendCodexWebsocketAPIKeyLifecyclePeerPubSubAdapter
  @api_key_close_frame {:close, 1008, "api key is no longer active"}
  @detection_timeout_ms 15_000
  @transport_barrier_payload "api-key-lifecycle-barrier"
  @primary_path "/backend-api/codex/responses"
  @backend_websocket_routes [
    {:backend_responses, "/backend-api/codex/responses"},
    {:backend_v1_responses, "/backend-api/codex/v1/responses"}
  ]
  @lifecycle_changes [:delete_key, :expire_key, :disable_pool, :delete_pool, :move_key]
  @fence_changes @lifecycle_changes

  # One peer node serves the whole module: starting a node costs far more than
  # any single scenario here, and every scenario uses fresh committed rows.
  setup_all do
    peer = start_lifecycle_peer!()
    on_exit(fn -> stop_lifecycle_peer!(peer) end)
    %{peer: peer}
  end

  # The owner is committed first, so its registered removal runs after every
  # cleanup a test registers later and takes the audit rows it authored with it.
  # `gateway_setup/1` then creates its key under this owner instead of
  # committing an owner of its own that nothing removes.
  setup do
    assert :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> assert :ok = Sandbox.mode(Repo, :manual) end)
    _owner = committed_bootstrap_owner_fixture!()
    :ok
  end

  for {route_label, path} <- @backend_websocket_routes, change <- @lifecycle_changes do
    @tag :distributed
    test "#{path} closes an idle websocket after #{change} on a peer node without a client frame",
         %{peer: peer} do
      route_label = unquote(route_label)
      path = unquote(path)
      change = unquote(change)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      {server, port} = start_public_endpoint_with_server!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "lifecycle-idle-#{change}-#{route_label}", path)

      try do
        assert_socket_ready!(server, setup.api_key.id)
        assert {:ok, _changed} = apply_change_on_peer!(peer, change, setup)

        {_conn, _websocket, frames} =
          receive_websocket_frames_until_close!(conn, websocket, ref)

        assert frames == [@api_key_close_frame]
        assert FakeUpstream.count(upstream) == 0
        assert request_count(setup) == 0
        assert attempt_count(setup) == 0
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  @tag :distributed
  test "#{@primary_path} closes an idle owner-forwarded websocket after expire_key on a peer node",
       %{peer: peer} do
    put_owner_forwarding!(true)
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    register_committed_setup_cleanup!(setup)
    {server, port} = start_public_endpoint_with_server!()

    {conn, websocket, ref} =
      public_websocket_connect!(port, setup, "lifecycle-idle-owner-forwarded", @primary_path)

    try do
      assert_socket_ready!(server, setup.api_key.id)
      assert {:ok, _changed} = apply_change_on_peer!(peer, :expire_key, setup)

      {_conn, _websocket, frames} = receive_websocket_frames_until_close!(conn, websocket, ref)

      assert frames == [@api_key_close_frame]
      assert FakeUpstream.count(upstream) == 0
      assert request_count(setup) == 0
      assert attempt_count(setup) == 0
    after
      Mint.HTTP.close(conn)
    end
  end

  for change <- @fence_changes, order <- [:create_then_processed, :processed_then_create] do
    @tag :distributed
    test "#{@primary_path} refuses #{order} after #{change} on a peer node while relay delivery is delayed",
         %{peer: peer} do
      change = unquote(change)
      order = unquote(order)
      upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      {server, port} = start_public_endpoint_with_server!()

      {conn, websocket, ref} =
        public_websocket_connect!(
          port,
          setup,
          "lifecycle-fence-#{change}-#{order}",
          @primary_path
        )

      :sys.suspend(PostgresBridge)
      on_exit(fn -> resume_if_suspended(PostgresBridge) end)

      try do
        assert_socket_ready!(server, setup.api_key.id)
        assert {:ok, _changed} = apply_change_on_peer!(peer, change, setup)

        {conn, websocket} =
          order
          |> fence_frames(setup)
          |> Enum.reduce({conn, websocket}, fn text, {conn, websocket} ->
            public_websocket_send_text!(conn, websocket, ref, text)
          end)

        {_conn, _websocket, frames} =
          receive_websocket_frames_until_close!(conn, websocket, ref)

        # No error frame precedes the close: the refusal is the policy close
        # itself, not a status-500 answer on a socket that stays open.
        assert frames == [@api_key_close_frame]
        assert FakeUpstream.count(upstream) == 0
        assert request_count(setup) == 0
        assert attempt_count(setup) == 0

        :sys.resume(PostgresBridge)
      after
        resume_if_suspended(PostgresBridge)
        Mint.HTTP.close(conn)
      end
    end
  end

  for owner_forwarding <- [false, true] do
    @tag :distributed
    test "#{@primary_path} never forwards a queued response.processed after the key expires on a peer node (owner forwarding #{owner_forwarding})",
         %{peer: peer} do
      put_owner_forwarding!(unquote(owner_forwarding))
      release_ref = make_ref()

      completed_frame =
        CodexPooler.JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_lifecycle_queued_processed",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          }
        })

      upstream =
        start_upstream(
          # provenance: synthetic_adversarial (held completed turn; no ack declared, none may reach upstream)
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 1,
              json: [valid: true],
              respond:
                FakeUpstream.barrier_websocket_frames([completed_frame],
                  notify: self(),
                  release_ref: release_ref
                )
            )
          ])
        )

      setup = gateway_setup(upstream)
      register_committed_setup_cleanup!(setup)
      {server, port} = start_public_endpoint_with_server!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "lifecycle-queued-processed", @primary_path)

      :sys.suspend(PostgresBridge)
      on_exit(fn -> resume_if_suspended(PostgresBridge) end)

      try do
        create_payload =
          CodexPooler.JSON.encode!(response_create_payload(setup, "lifecycle-queued-admitted"))

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, create_payload)

        assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^release_ref},
                       @detection_timeout_ms

        processed_payload =
          CodexPooler.JSON.encode!(%{
            "type" => "response.processed",
            "response_id" => "resp_lifecycle_queued_processed"
          })

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, processed_payload)
        {conn, websocket} = websocket_transport_barrier!(conn, websocket, ref)
        assert_socket_queue_length!(server, 1)

        assert {:ok, _expired} = apply_change_on_peer!(peer, :expire_key, setup)
        assert :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)

        assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^release_ref},
                       @detection_timeout_ms

        {_conn, _websocket, frames} = receive_websocket_frames_until_close!(conn, websocket, ref)

        assert [{:text, final_frame}, @api_key_close_frame] = frames
        assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(final_frame)
        assert FakeUpstream.count(upstream) == 1
        assert :ok = FakeUpstream.verify!(upstream)

        assert [%Request{status: "succeeded"} = request] =
                 Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

        refute request.request_metadata["response_processed"]
        assert attempt_count(setup) == 1

        :sys.resume(PostgresBridge)
      after
        resume_if_suspended(PostgresBridge)
        Mint.HTTP.close(conn)
      end
    end
  end

  defp fence_frames(:create_then_processed, setup),
    do: [fence_create_frame(setup), fence_processed_frame()]

  defp fence_frames(:processed_then_create, setup),
    do: [fence_processed_frame(), fence_create_frame(setup)]

  defp fence_create_frame(setup),
    do: CodexPooler.JSON.encode!(response_create_payload(setup, "lifecycle-fence-create"))

  defp fence_processed_frame do
    CodexPooler.JSON.encode!(%{
      "type" => "response.processed",
      "response_id" => "resp_lifecycle_fence"
    })
  end

  defp response_create_payload(setup, marker) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input(marker),
      "stream" => true,
      "generate" => true
    }
  end

  defp apply_change_on_peer!(peer, :delete_key, setup),
    do: peer_call!(peer, :delete_key, [owner_scope!(setup), setup.api_key.id])

  defp apply_change_on_peer!(peer, :expire_key, setup) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    peer_call!(peer, :expire_key, [owner_scope!(setup), setup.api_key.id, past])
  end

  defp apply_change_on_peer!(peer, :disable_pool, setup),
    do: peer_call!(peer, :disable_pool, [owner_scope!(setup), setup.pool.id])

  defp apply_change_on_peer!(peer, :delete_pool, setup),
    do: peer_call!(peer, :delete_pool, [owner_scope!(setup), setup.pool.id])

  # The target Pool belongs to the committed owner, so the owner's registered
  # removal takes it and the moved key with it.
  defp apply_change_on_peer!(peer, :move_key, setup) do
    scope = owner_scope!(setup)

    assert {:ok, target_pool} =
             Pools.create_pool(scope, %{
               slug: "lifecycle-move-target-#{System.unique_integer([:positive])}",
               name: "Lifecycle move target"
             })

    peer_call!(peer, :move_key, [scope, setup.api_key.id, target_pool.id])
  end

  defp peer_call!(peer, function, args),
    do: :erpc.call(peer.node, @peer_module, function, args, @detection_timeout_ms)

  defp owner_scope!(setup) do
    setup.api_key.created_by_user_id
    |> then(&Repo.get!(User, &1))
    |> Scope.for_user(["instance_owner"])
  end

  # Deleting a Pool cascades its Pool-scoped rows, which is also how
  # `cleanup_unboxed_pool!/1` finds the upstream identity it removes, so the
  # identity-scoped rows are removed by their captured id as well. Activating
  # the identity also enqueues its reconciliation job, which references neither
  # the owner nor the Pool by a foreign key and would otherwise stay committed.
  defp register_committed_setup_cleanup!(setup) do
    identity_id = setup.identity.id

    on_exit(fn ->
      cleanup_unboxed_pool!(setup)

      Repo.delete_all(
        from(job in "oban_jobs",
          where: fragment("?->>'upstream_identity_id'", job.args) == ^identity_id
        )
      )

      Repo.delete_all(
        from(window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity_id)
      )

      Repo.delete_all(
        from(secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity_id)
      )

      Repo.delete_all(from(identity in UpstreamIdentity, where: identity.id == ^identity_id))
    end)
  end

  defp put_owner_forwarding!(enabled) do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)

        :error ->
          Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)
  end

  defp request_count(setup) do
    Repo.aggregate(from(request in Request, where: request.pool_id == ^setup.pool.id), :count)
  end

  defp attempt_count(setup) do
    Repo.aggregate(
      from(attempt in Attempt,
        join: request in Request,
        on: request.id == attempt.request_id,
        where: request.pool_id == ^setup.pool.id
      ),
      :count
    )
  end

  defp assert_socket_ready!(server, api_key_id) do
    await_socket_state!(
      server,
      &(Map.get(&1, :api_key_id) == api_key_id),
      System.monotonic_time(:millisecond) + @detection_timeout_ms
    )
  end

  defp assert_socket_queue_length!(server, expected_length) do
    state = websocket_state!(server)
    assert :queue.len(state.queued_response_payloads) == expected_length
  end

  defp await_socket_state!(server, predicate, deadline) do
    state = websocket_state!(server)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> await_socket_state!(server, predicate, deadline)
        end

      true ->
        flunk("websocket state did not reach the expected condition")
    end
  end

  defp websocket_state!(server) do
    assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
    {_socket, handler_state} = :sys.get_state(connection_pid)
    handler_state.connection.websock_state
  end

  defp websocket_transport_barrier!(conn, websocket, ref) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, {:ping, @transport_barrier_payload})

    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    await_transport_barrier!(
      conn,
      websocket,
      ref,
      System.monotonic_time(:millisecond) + @detection_timeout_ms
    )
  end

  defp await_transport_barrier!(conn, websocket, ref, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            await_transport_barrier!(conn, websocket, ref, deadline)

          {:ok, conn, responses} ->
            {websocket, pong?} = decode_transport_barrier!(websocket, ref, responses)

            if pong?,
              do: {conn, websocket},
              else: await_transport_barrier!(conn, websocket, ref, deadline)
        end
    after
      timeout -> flunk("timed out waiting for websocket transport barrier")
    end
  end

  defp decode_transport_barrier!(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, false}, fn
      {:data, ^ref, data}, {websocket, pong?} ->
        assert {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)

        unexpected_frames =
          Enum.reject(frames, fn
            {:pong, @transport_barrier_payload} -> true
            frame -> metadata_control_frame?(frame)
          end)

        assert unexpected_frames == []
        {websocket, pong? or {:pong, @transport_barrier_payload} in frames}

      _response, acc ->
        acc
    end)
  end

  defp receive_websocket_frames_until_close!(conn, websocket, ref, frames \\ []) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            receive_websocket_frames_until_close!(conn, websocket, ref, frames)

          {:ok, conn, responses} ->
            {websocket, frames, closed?} =
              Enum.reduce(responses, {websocket, frames, false}, fn
                {:data, ^ref, data}, {websocket, frames, closed?} ->
                  assert {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
                  decoded = Enum.reject(decoded, &metadata_control_frame?/1)

                  {websocket, frames ++ decoded,
                   closed? or Enum.any?(decoded, &match?({:close, _, _}, &1))}

                _response, acc ->
                  acc
              end)

            if closed?,
              do: {conn, websocket, frames},
              else: receive_websocket_frames_until_close!(conn, websocket, ref, frames)

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket frame receive failed: #{inspect(reason)}")
        end
    after
      @detection_timeout_ms -> flunk("timed out waiting for websocket close")
    end
  end

  defp metadata_control_frame?({:text, frame}) when is_binary(frame),
    do: metadata_control_frame?(frame)

  defp metadata_control_frame?(frame) when is_binary(frame) do
    match?({:ok, %{"type" => "codex.response.metadata"}}, CodexPooler.JSON.decode(frame))
  end

  defp metadata_control_frame?(_frame), do: false

  defp resume_if_suspended(process) do
    case Process.whereis(process) do
      pid when is_pid(pid) ->
        try do
          :sys.resume(process)
        catch
          :exit, _reason -> :ok
        end

      nil ->
        :ok
    end
  end

  defp start_lifecycle_peer! do
    distribution = ensure_test_distribution_started!()

    try do
      peer_name = String.to_atom("api_key_lifecycle_peer_#{System.unique_integer([:positive])}")

      assert {:ok, peer_pid, peer_node} =
               :peer.start_link(%{
                 name: peer_name,
                 args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
               })

      peer = %{distribution: distribution, name: peer_name, node: peer_node, pid: peer_pid}

      try do
        Process.unlink(peer_pid)
        assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

        assert {:ok, _applications} =
                 :erpc.call(peer_node, Application, :ensure_all_started, [:elixir])

        compiled = :erpc.call(peer_node, Code, :compile_string, [peer_source()])

        assert compiled |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
                 Enum.sort([@peer_module, @peer_pubsub_adapter])

        repo_config =
          :codex_pooler
          |> Application.fetch_env!(Repo)
          |> Keyword.merge(pool: DBConnection.ConnectionPool, pool_size: 2)

        assert :ok =
                 :erpc.call(peer_node, @peer_module, :start, [repo_config], @detection_timeout_ms)

        peer
      catch
        kind, reason ->
          stop_lifecycle_peer!(peer)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    catch
      kind, reason ->
        stop_test_distribution!(distribution)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp stop_lifecycle_peer!(peer) do
    if Process.alive?(peer.pid) do
      monitor = Process.monitor(peer.pid)
      :peer.stop(peer.pid)
      assert_receive {:DOWN, ^monitor, :process, _, _}, @detection_timeout_ms
    end

    PeerRegistry.assert_peer_absent!(peer.name, peer_node: peer.node)
    stop_test_distribution!(peer.distribution)
  end

  defp ensure_test_distribution_started! do
    case Node.alive?() do
      true ->
        %{node_started?: false, previous_partition_guard: :unchanged}

      false ->
        ensure_epmd_started!()
        previous_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
        # Also on_exit: a failure before the peer's cleanup is registered leaves the guard off.
        on_exit(fn -> restore_partition_guard(previous_partition_guard) end)
        Application.put_env(:kernel, :prevent_overlapping_partitions, false)

        node_name =
          String.to_atom("api_key_lifecycle_test_#{System.unique_integer([:positive])}")

        assert {:ok, _pid} = :net_kernel.start([node_name, :shortnames])

        %{node_started?: true, previous_partition_guard: previous_partition_guard}
    end
  end

  defp ensure_epmd_started! do
    case :erl_epmd.names() do
      {:ok, _names} ->
        :ok

      {:error, _reason} ->
        assert {_output, 0} = System.cmd("epmd", ["-daemon"])
        PeerRegistry.assert_epmd_ready!()
    end
  end

  defp stop_test_distribution!(distribution) do
    if distribution.node_started? and Node.alive?() do
      assert :ok = :net_kernel.stop()
    end

    restore_partition_guard(distribution.previous_partition_guard)
  end

  defp restore_partition_guard({:ok, value}),
    do: Application.put_env(:kernel, :prevent_overlapping_partitions, value)

  defp restore_partition_guard(:error),
    do: Application.delete_env(:kernel, :prevent_overlapping_partitions)

  defp restore_partition_guard(:unchanged), do: :ok

  # The peer runs the real operator functions against the shared database. It
  # starts no application tree, so it gets a PubSub whose adapter reaches no
  # other node: the only path from its change to this node's socket is the
  # PostgreSQL relay, exactly as between two application nodes that share only
  # the database.
  defp peer_source do
    """
    defmodule #{inspect(@peer_pubsub_adapter)} do
      @behaviour Phoenix.PubSub.Adapter

      def node_name(_adapter_name), do: node()

      def child_spec(opts) do
        adapter_name = Keyword.fetch!(opts, :adapter_name)
        %{id: adapter_name, start: {Agent, :start_link, [fn -> adapter_name end]}}
      end

      def broadcast(_adapter_name, _topic, _message, _dispatcher), do: :ok
      def direct_broadcast(_adapter_name, _node_name, _topic, _message, _dispatcher), do: :ok
    end

    defmodule #{inspect(@peer_module)} do
      def start(repo_config) do
        # Some operator paths branch on `Mix.env/0` at runtime, so the peer runs
        # them under the same Mix environment as this test node.
        {:ok, _applications} = Application.ensure_all_started(:mix)
        Mix.env(:test)
        Application.put_env(:codex_pooler, CodexPooler.Repo, repo_config)
        {:ok, _applications} = Application.ensure_all_started(:ecto_sql)
        {:ok, _applications} = Application.ensure_all_started(:phoenix_pubsub)
        {:ok, repo_pid} = CodexPooler.Repo.start_link()
        Process.unlink(repo_pid)

        {:ok, pubsub_pid} =
          Phoenix.PubSub.Supervisor.start_link(
            name: CodexPooler.PubSub,
            adapter: #{inspect(@peer_pubsub_adapter)}
          )

        Process.unlink(pubsub_pid)
        :ok
      end

      def delete_key(scope, api_key_id), do: CodexPooler.Access.delete_api_key(scope, api_key_id)

      def expire_key(scope, api_key_id, expires_at),
        do: CodexPooler.Access.update_api_key(scope, api_key_id, %{expires_at: expires_at})

      # The operator form submits the key's status with every edit.
      def move_key(scope, api_key_id, pool_id),
        do: CodexPooler.Access.update_api_key(scope, api_key_id, %{pool_id: pool_id, status: "active"})

      def disable_pool(scope, pool_id),
        do: CodexPooler.Pools.change_pool_status(scope, pool_id, "disabled")

      def delete_pool(scope, pool_id) do
        with {:ok, archived} <- CodexPooler.Pools.change_pool_status(scope, pool_id, "archived") do
          CodexPooler.Pools.delete_archived_pool(scope, archived, archived.slug)
        end
      end
    end
    """
  end
end
