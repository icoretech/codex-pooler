defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketFirewallRevocationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.{Cache, Settings}
  alias CodexPooler.Repo

  @websocket_frame_timeout 1_000
  @large_websocket_frame_timeout 5_000
  @websocket_transport_barrier_payload "codex-pooler-test-barrier"
  @model_serving_websocket_routes [
    {:backend_responses, "/backend-api/codex/responses"},
    {:backend_v1_responses, "/backend-api/codex/v1/responses"},
    {:public_v1_responses, "/v1/responses"}
  ]

  test "an allowed locally applied firewall version keeps an open websocket usable" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_ws_firewall_allowed",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "ws-firewall-allowed")

    try do
      assert :ok = Cache.subscribe_applied()
      settings = InstanceSettings.ensure_singleton!()

      assert {:ok, allowed_settings} =
               InstanceSettings.update_system_settings(settings, %{
                 "ingress" => %{"firewall_allowlist" => ["127.0.0.1/32"]}
               })

      assert_cache_applied!(allowed_settings.lock_version)

      payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("allowed firewall update"),
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.completed"} = Jason.decode!(frame)
      assert FakeUpstream.count(upstream) == 1
    after
      Mint.HTTP.close(conn)
    end
  end

  for {route_label, path} <- @model_serving_websocket_routes do
    @tag :capture_log
    test "#{path} revokes an idle websocket after the settings singleton is recreated" do
      route_label = unquote(route_label)
      path = unquote(path)
      setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
      version_7 = advance_firewall_to_version_7!()
      port = start_public_endpoint!()

      {conn, websocket, ref} =
        public_websocket_connect!(port, setup, "ws-firewall-recreated-#{route_label}", path)

      try do
        assert version_7.lock_version == 7
        assert_recreated_firewall_denial!()

        {_conn, _websocket, frames} =
          receive_public_websocket_frames_until_close!(conn, websocket, ref)

        assert frames == [{:close, 1008, "client IP is no longer allowed"}]
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  @tag :capture_log
  test "a busy recreated-row revocation flushes its admitted turn then drops queued and new work" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_ws_firewall_busy",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    version_7 = advance_firewall_to_version_7!()
    {server, port} = start_public_endpoint_with_server!()

    {conn, websocket, ref, _response_headers} =
      public_websocket_connect_with_request_headers!(
        port,
        setup,
        "ws-firewall-busy",
        "/backend-api/codex/responses",
        [{"x-forwarded-for", "198.51.100.20, 203.0.113.99"}]
      )

    try do
      first_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("admitted turn"),
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, first_payload)
      assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref}, 1_000

      queued_payload =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_firewall_queued",
              "output" => "queued output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_firewall_busy"
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, queued_payload)
      {conn, websocket} = public_websocket_transport_barrier!(conn, websocket, ref)
      assert_public_websocket_queue_length!(server, 1)

      {{conn, websocket}, logs} =
        with_log(
          [
            level: :warning,
            format: "$metadata$message\n",
            metadata: [:scope, :reason]
          ],
          fn ->
            assert version_7.lock_version == 7
            assert_recreated_firewall_denial!()
            assert_public_websocket_queue_length!(server, 0)

            new_payload =
              Jason.encode!(%{
                "type" => "response.create",
                "model" => setup.model.exposed_model_id,
                "input" => native_text_input("new work after revocation"),
                "stream" => true,
                "generate" => true
              })

            {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, new_payload)
            {conn, websocket} = public_websocket_transport_barrier!(conn, websocket, ref)
            assert_public_websocket_queue_length!(server, 0)
            {conn, websocket}
          end
        )

      assert_sanitized_websocket_revocation_log!(logs, setup)
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

      {_conn, _websocket, frames} =
        receive_public_websocket_frames_until_close!(conn, websocket, ref)

      assert [{:text, final_frame}, {:close, 1008, "client IP is no longer allowed"}] = frames
      assert %{"type" => "response.completed"} = Jason.decode!(final_frame)
      assert FakeUpstream.count(upstream) == 1

      assert Repo.aggregate(
               from(request in Request, where: request.pool_id == ^setup.pool.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(attempt in Attempt,
                 join: request in Request,
                 on: request.id == attempt.request_id,
                 where: request.pool_id == ^setup.pool.id
               ),
               :count
             ) == 1
    after
      Mint.HTTP.close(conn)
    end
  end

  @tag :distributed
  test "a post-start peer setup failure restores every acquired distribution resource" do
    initial_node = Node.self()
    initial_connected_nodes = MapSet.new(Node.list(:connected))
    initial_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
    test_pid = self()

    assert_raise RuntimeError, "forced post-start peer setup failure", fn ->
      start_instance_settings_broadcast_peer!(fn peer ->
        peer_monitor = Process.monitor(peer.pid)

        started_distribution_node =
          if peer.distribution.node_started?, do: Node.self()

        send(
          test_pid,
          {:partial_peer_started, peer, peer_monitor, started_distribution_node}
        )

        raise "forced post-start peer setup failure"
      end)
    end

    assert_receive {:partial_peer_started, peer, peer_monitor, started_distribution_node}

    try do
      assert_receive {:DOWN, ^peer_monitor, :process, peer_pid, _reason},
                     @websocket_frame_timeout

      assert peer_pid == peer.pid
      refute peer.node in Node.list(:connected)
      assert Node.self() == initial_node
      assert MapSet.new(Node.list(:connected)) == initial_connected_nodes

      assert Application.fetch_env(:kernel, :prevent_overlapping_partitions) ==
               initial_partition_guard

      assert_epmd_names_released!([peer.node, started_distribution_node])
    after
      stop_instance_settings_broadcast_peer!(peer)
    end
  end

  @tag :capture_log
  @tag :distributed
  test "a connected peer invalidation reloads the receiving cache and revokes its live websocket" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    version_7 = advance_firewall_to_version_7!()
    peer = start_instance_settings_broadcast_peer!()
    register_instance_settings_broadcast_peer_cleanup!(peer)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_websocket_connect!(port, setup, "ws-firewall-peer-origin")

    try do
      assert version_7.lock_version == 7
      recreated_version_1 = recreate_firewall_settings!()

      denied_version_2 =
        recreated_version_1
        |> Settings.changeset(%{
          "ingress" => %{"firewall_allowlist" => ["203.0.113.10/32"]}
        })
        |> Repo.update!()

      assert denied_version_2.lock_version == 2
      assert InstanceSettings.current().lock_version == 1
      assert :ok = Cache.subscribe_applied()

      assert :ok = :erpc.call(peer.node, Cache, :broadcast_update, [denied_version_2])

      assert_receive {Cache, {:applied, 2}}, @websocket_frame_timeout
      assert InstanceSettings.current().lock_version == 2

      {_conn, _websocket, code, reason} =
        public_websocket_receive_close!(conn, websocket, ref)

      assert {code, reason} == {1008, "client IP is no longer allowed"}
    after
      Mint.HTTP.close(conn)
      stop_instance_settings_broadcast_peer!(peer)
    end
  end

  defp advance_firewall_to_version_7! do
    assert :ok = Cache.subscribe_applied()
    version_1 = InstanceSettings.ensure_singleton!()
    assert version_1.lock_version == 1

    Enum.reduce(2..7, version_1, fn expected_version, settings ->
      assert {:ok, updated} =
               InstanceSettings.update_system_settings(settings, %{
                 "ingress" => %{
                   "firewall_allowlist" => [
                     "127.0.0.1/32",
                     "198.51.100.#{expected_version}/32"
                   ]
                 }
               })

      assert updated.lock_version == expected_version
      assert_cache_applied!(expected_version)
      updated
    end)
  end

  defp assert_recreated_firewall_denial! do
    recreated_version_1 = recreate_firewall_settings!()

    attrs =
      %{
        "ingress" => %{"firewall_allowlist" => ["203.0.113.10/32"]},
        "smtp" => %{
          "enabled" => true,
          "host" => "smtp.example.com",
          "username" => "mailer",
          "from" => "no-reply@example.com"
        }
      }
      |> InstanceSettings.put_smtp_password("smtp-password-sentinel")
      |> InstanceSettings.put_metrics_bearer_token("metrics-token-sentinel")

    assert {:ok, denied_version_2} =
             InstanceSettings.update_system_settings(recreated_version_1, attrs)

    assert denied_version_2.lock_version == 2
    assert_cache_applied!(2)
    assert InstanceSettings.current().lock_version == 2
    denied_version_2
  end

  defp recreate_firewall_settings! do
    _ = :sys.get_state(Cache)
    assert {1, nil} = Repo.delete_all(Settings)
    recreated_version_1 = InstanceSettings.ensure_singleton!()
    assert recreated_version_1.lock_version == 1
    assert {:ok, published_version_1} = Cache.put(recreated_version_1)
    assert published_version_1.lock_version == 1
    assert_cache_applied!(1)
    assert InstanceSettings.current().lock_version == 1
    recreated_version_1
  end

  defp assert_cache_applied!(expected_version) do
    receive do
      {Cache, {:applied, ^expected_version}} -> :ok
      {Cache, {:applied, _other_version}} -> assert_cache_applied!(expected_version)
    after
      @websocket_frame_timeout ->
        flunk("timed out waiting for instance settings cache version #{expected_version}")
    end
  end

  defp start_instance_settings_broadcast_peer!(after_peer_start \\ fn _peer -> :ok end) do
    distribution = ensure_test_distribution_started!()

    try do
      peer_name = String.to_atom("websocket_settings_peer_#{System.unique_integer([:positive])}")

      assert {:ok, peer_pid, peer_node} =
               :peer.start_link(%{
                 name: peer_name,
                 args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
               })

      peer = %{distribution: distribution, node: peer_node, pid: peer_pid}

      try do
        Process.unlink(peer_pid)
        after_peer_start.(peer)
        assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

        assert {:ok, _applications} =
                 :erpc.call(peer_node, Application, :ensure_all_started, [:phoenix_pubsub])

        assert [{CodexPoolerWeb.Runtime.BackendCodexWebsocketBroadcastPeer, _beam}] =
                 :erpc.call(peer_node, Code, :compile_string, [broadcast_peer_source()])

        supervisor =
          :erpc.call(
            peer_node,
            CodexPoolerWeb.Runtime.BackendCodexWebsocketBroadcastPeer,
            :start,
            []
          )

        assert is_pid(supervisor)
        assert peer_node in Node.list(:connected)
        peer
      catch
        kind, reason ->
          stop_instance_settings_broadcast_peer_process!(peer)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    catch
      kind, reason ->
        stop_test_distribution!(distribution)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp stop_instance_settings_broadcast_peer!(%{distribution: distribution} = peer) do
    try do
      stop_instance_settings_broadcast_peer_process!(peer)
    after
      stop_test_distribution!(distribution)
    end

    :ok
  end

  defp stop_instance_settings_broadcast_peer_process!(%{node: peer_node, pid: peer_pid}) do
    if Process.alive?(peer_pid) do
      peer_monitor = Process.monitor(peer_pid)
      :peer.stop(peer_pid)

      assert_receive {:DOWN, ^peer_monitor, :process, ^peer_pid, _reason},
                     @websocket_frame_timeout
    end

    refute peer_node in Node.list(:connected)
    :ok
  end

  defp stop_test_distribution!(distribution) do
    try do
      if distribution.node_started? and Node.alive?() do
        :ok = :net_kernel.stop()
      end
    after
      restore_partition_guard(distribution.previous_partition_guard)

      if distribution.epmd_started? do
        case :erl_epmd.names() do
          {:ok, _names} -> assert {_output, 0} = System.cmd("epmd", ["-kill"])
          {:error, _reason} -> :ok
        end
      end
    end

    :ok
  end

  defp register_instance_settings_broadcast_peer_cleanup!(peer) do
    on_exit(fn -> stop_instance_settings_broadcast_peer!(peer) end)
  end

  defp assert_public_websocket_queue_length!(server, expected_length) do
    assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
    {_socket, handler_state} = :sys.get_state(connection_pid)
    websock_state = handler_state.connection.websock_state

    assert :queue.len(websock_state.queued_response_payloads) == expected_length
  end

  defp public_websocket_transport_barrier!(conn, websocket, ref) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, {:ping, @websocket_transport_barrier_payload})

    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    await_public_websocket_transport_barrier!(
      conn,
      websocket,
      ref,
      System.monotonic_time(:millisecond) + @large_websocket_frame_timeout
    )
  end

  defp await_public_websocket_transport_barrier!(conn, websocket, ref, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            await_public_websocket_transport_barrier!(conn, websocket, ref, deadline)

          {:ok, conn, responses} ->
            {websocket, pong?} = decode_transport_barrier_responses!(websocket, ref, responses)

            if pong? do
              {conn, websocket}
            else
              await_public_websocket_transport_barrier!(conn, websocket, ref, deadline)
            end
        end
    after
      timeout -> flunk("timed out waiting for websocket transport barrier")
    end
  end

  defp decode_transport_barrier_responses!(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, false}, fn
      {:data, ^ref, response_data}, {websocket, pong?} ->
        assert {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, response_data)

        unexpected_frames =
          Enum.reject(frames, fn
            {:pong, @websocket_transport_barrier_payload} -> true
            frame -> metadata_control_frame?(frame)
          end)

        assert unexpected_frames == []

        {websocket, pong? or {:pong, @websocket_transport_barrier_payload} in frames}

      _response, state ->
        state
    end)
  end

  defp assert_sanitized_websocket_revocation_log!(logs, setup) do
    revocation_lines =
      logs
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "ingress firewall denied"))

    assert [line] = revocation_lines
    assert line =~ "scope=runtime"
    assert line =~ "reason=websocket_revoked"

    for forbidden <- [
          "127.0.0.1",
          "198.51.100.20",
          "203.0.113.99",
          "203.0.113.10",
          "x-forwarded-for",
          "admitted turn",
          "queued output",
          "new work after revocation",
          "client IP is no longer allowed",
          setup.authorization,
          setup.raw_key,
          "upstream-token",
          "smtp-password-sentinel",
          "metrics-token-sentinel"
        ] do
      refute logs =~ forbidden
    end
  end

  defp ensure_test_distribution_started! do
    case Node.alive?() do
      true ->
        %{epmd_started?: false, node_started?: false, previous_partition_guard: :unchanged}

      false ->
        epmd_started? = ensure_epmd_started!()
        previous_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)

        distribution = %{
          epmd_started?: epmd_started?,
          node_started?: true,
          previous_partition_guard: previous_partition_guard
        }

        try do
          Application.put_env(:kernel, :prevent_overlapping_partitions, false)

          node_name =
            String.to_atom("websocket_settings_test_#{System.unique_integer([:positive])}")

          assert {:ok, _pid} = :net_kernel.start([node_name, :shortnames])
          distribution
        catch
          kind, reason ->
            stop_test_distribution!(distribution)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
    end
  end

  defp ensure_epmd_started! do
    case :erl_epmd.names() do
      {:ok, _names} ->
        false

      {:error, _reason} ->
        assert {_output, 0} = System.cmd("epmd", ["-daemon"])
        true
    end
  end

  defp restore_partition_guard({:ok, value}) do
    Application.put_env(:kernel, :prevent_overlapping_partitions, value)
  end

  defp restore_partition_guard(:error) do
    Application.delete_env(:kernel, :prevent_overlapping_partitions)
  end

  defp restore_partition_guard(:unchanged), do: :ok

  defp assert_epmd_names_released!(nodes) do
    expected_names =
      nodes
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn node ->
        node
        |> Atom.to_string()
        |> String.split("@", parts: 2)
        |> hd()
      end)
      |> MapSet.new()

    await_epmd_names_released!(expected_names, System.monotonic_time(:millisecond) + 1_000)
  end

  defp await_epmd_names_released!(expected_names, deadline) do
    registered_names =
      case :erl_epmd.names() do
        {:ok, names} ->
          names
          |> Enum.map(fn {name, _port} -> List.to_string(name) end)
          |> MapSet.new()

        {:error, _reason} ->
          MapSet.new()
      end

    remaining_names = MapSet.intersection(expected_names, registered_names)

    cond do
      MapSet.size(remaining_names) == 0 ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> await_epmd_names_released!(expected_names, deadline)
        end

      true ->
        flunk("EPMD still registers acquired nodes: #{inspect(remaining_names)}")
    end
  end

  defp broadcast_peer_source do
    """
    defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketBroadcastPeer do
      def start do
        {:ok, supervisor} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: CodexPooler.PubSub}],
            strategy: :one_for_one
          )

        Process.unlink(supervisor)
        supervisor
      end
    end
    """
  end

  defp receive_public_websocket_frames_until_close!(conn, websocket, ref, frames \\ []) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, frames, closed?} =
              Enum.reduce(responses, {websocket, frames, false}, fn
                {:data, ^ref, data}, {websocket, frames, closed?} ->
                  {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
                  decoded = Enum.reject(decoded, &metadata_control_frame?/1)

                  {websocket, frames ++ decoded,
                   closed? or Enum.any?(decoded, &match?({:close, _, _}, &1))}

                _response, acc ->
                  acc
              end)

            if closed? do
              {conn, websocket, frames}
            else
              receive_public_websocket_frames_until_close!(conn, websocket, ref, frames)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket frame receive failed: #{inspect(reason)}")

          :unknown ->
            receive_public_websocket_frames_until_close!(conn, websocket, ref, frames)
        end
    after
      @large_websocket_frame_timeout -> flunk("timed out waiting for websocket close")
    end
  end

  defp metadata_control_frame?({:text, frame}) when is_binary(frame),
    do: metadata_control_frame?(frame)

  defp metadata_control_frame?(frame) when is_binary(frame) do
    match?({:ok, %{"type" => "codex.response.metadata"}}, Jason.decode(frame))
  end

  defp metadata_control_frame?(_frame), do: false
end
