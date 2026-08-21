defmodule CodexPooler.Gateway.Transports.WebsocketOwnerMixedReleaseTest do
  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerPreviousReleaseFixture, as: Fixture
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo

  @peer_timeout 10_000
  @source_commit "a589116bb733fb53c58520637ea70382c68e6bd3"

  setup_all do
    ensure_distribution_started!()
    :ok
  end

  setup do
    reset_bootstrap_state_fixture!()
    auth = auth_fixture()
    on_exit(&cleanup_local_owners/0)
    {:ok, auth: auth}
  end

  test "fixture records the historical legacy request protocol" do
    assert Fixture.provenance() == %{
             source_commit: @source_commit,
             source_path:
               "lib/codex_pooler/gateway/transports/websocket/websocket_owner_forwarder.ex",
             public_entrypoint: {:remote_submit_request, 4},
             owner_resolution: {:ensure_remote_owner, 4},
             submission: {:submit_remote_owner_request, 5},
             visibility: {:track_request_visibility, 1}
           }
  end

  test "previous release /4 executes historical owner resolution and submission", %{auth: auth} do
    caller = start_peer!(:previous_path_caller)
    owner_peer = start_peer!(:previous_path_owner)
    start_runtime!(owner_peer.node)
    assert {:module, WebsocketOwnerForwarder} = Fixture.load_forwarder(owner_peer.node, self())

    %{session: session} = owner_session_fixture(auth, owner_peer.node, "old-old")
    terminal = Jason.encode!(%{"type" => "response.completed", "response" => %{}})
    owner = start_owner!(owner_peer.node, session, [terminal])
    attached = attach!(owner_peer.node, session.id, "corr-old-old")
    assert {:module, WebsocketOwnerForwarder} = Fixture.load_forwarder(owner_peer.node, self())
    request = :erpc.call(caller.node, Fixture, :historical_request, [self()])
    opts = :erpc.call(caller.node, Fixture, :legacy_opts, [self()])

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             :erpc.call(caller.node, Fixture, :call_current_owner, [
               owner_peer.node,
               session.id,
               attached,
               request,
               opts
             ])

    assert_exactly_once({:previous_release_protocol, :remote_submit_request_4})
    assert_exactly_once({:previous_release_protocol, :ensure_remote_owner_4})
    assert_exactly_once({:previous_release_protocol, :submit_remote_owner_request_5})
    assert_exactly_once({:previous_release_protocol, :do_submit_remote_owner_request_6})
    assert_exactly_once({:mixed_release_upstream_send, owner_peer.node})
    assert_exactly_once({:mixed_release_request_materialized, :synthetic})
    assert_receive {:websocket_owner_frame, "corr-old-old", 1, {:data, ^terminal}}
    assert_receive {:websocket_owner_frame, "corr-old-old", 1, :complete}
    assert :erpc.call(owner_peer.node, Process, :alive?, [owner])
    assert_owner_idle(owner_peer.node, session.id, owner)
    assert_no_external_network([caller, owner_peer])
  end

  test "current v1 proxy rejects a previous owner before callback or upstream work", %{auth: auth} do
    previous = start_peer!(:previous_owner)
    current = start_peer!(:current_proxy)
    start_runtime!(previous.node)

    assert {:module, WebsocketOwnerForwarder} = Fixture.load_forwarder(previous.node, self())

    refute :erpc.call(previous.node, :erlang, :function_exported, [
             WebsocketOwnerForwarder,
             :remote_submit_request_v1,
             3
           ])

    %{session: session, token: token} = owner_session_fixture(auth, previous.node, "new-old")
    owner = start_owner!(previous.node, session)
    attached = attach!(previous.node, session.id, "corr-new-old")

    request = owner_request(Ecto.UUID.generate(), version: 1)

    assert {:rpc_receipt, rpc_arguments, {:error, :owner_unavailable}} =
             :erpc.call(current.node, Fixture, :call_current_v1, [
               previous.node,
               session.id,
               attached,
               request,
               @peer_timeout
             ])

    refute contains_function?(rpc_arguments)

    assert_owner_idle(previous.node, session.id, owner)
    assert :erpc.call(previous.node, Process, :alive?, [owner])
    assert Repo.get!(CodexSession, session.id).owner_lease_token == token
    assert_no_forbidden_work()
    assert_no_external_network([previous, current])
  end

  test "previous caller rejects current legacy entrypoint before every function sentinel", %{
    auth: auth
  } do
    previous = start_peer!(:previous_caller)
    current = start_peer!(:current_owner)
    start_runtime!(current.node)

    %{session: session, token: token} = owner_session_fixture(auth, current.node, "old-new")
    owner = start_owner!(current.node, session)
    attached = attach!(current.node, session.id, "corr-old-new")

    request = :erpc.call(previous.node, Fixture, :legacy_request, [self()])
    opts = :erpc.call(previous.node, Fixture, :legacy_opts, [self()])
    assert contains_function?(request)
    assert contains_function?(opts)

    assert {:error, :owner_unavailable} =
             :erpc.call(previous.node, Fixture, :call_current_owner, [
               current.node,
               session.id,
               attached,
               request,
               opts
             ])

    assert_owner_idle(current.node, session.id, owner)
    assert :erpc.call(current.node, Process, :alive?, [owner])
    assert Repo.get!(CodexSession, session.id).owner_lease_token == token
    assert_no_forbidden_work()
    assert_no_external_network([previous, current])
  end

  test "current peers with different dispatch BEAM identities complete one v1 terminal", %{
    auth: auth
  } do
    proxy = start_peer!(:different_dispatch_proxy)
    owner_peer = start_peer!(:different_dispatch_owner)
    start_runtime!(owner_peer.node)

    proxy_identity = Fixture.load_current_dispatch_identity(proxy.node, "proxy")
    owner_identity = Fixture.load_current_dispatch_identity(owner_peer.node, "owner")
    refute proxy_identity == owner_identity

    upstream_identity_id = Ecto.UUID.generate()

    assert {:module, CodexPooler.Upstreams} =
             Fixture.load_synthetic_identity_lookup(owner_peer.node, upstream_identity_id)

    %{session: session} = owner_session_fixture(auth, owner_peer.node, "current-current")
    terminal = Jason.encode!(%{"type" => "response.completed", "response" => %{}})
    owner = start_owner!(owner_peer.node, session, [terminal])
    attached = attach!(owner_peer.node, session.id, "corr-current-current")
    request = owner_request(upstream_identity_id, version: 1, submission_notification?: true)

    assert {:rpc_receipt, rpc_arguments,
            {:websocket_owner_submission_accepted,
             {:ok, %{terminal: "response.completed", status: 200}}}} =
             :erpc.call(proxy.node, Fixture, :call_current_v1, [
               owner_peer.node,
               session.id,
               attached,
               request,
               @peer_timeout
             ])

    refute contains_function?(rpc_arguments)

    assert_exactly_once({:mixed_release_upstream_send, owner_peer.node})
    assert_exactly_once({:mixed_release_request_materialized, :synthetic})
    assert_exactly_once({:websocket_owner_frame, "corr-current-current", 1, {:data, terminal}})
    assert_exactly_once({:websocket_owner_frame, "corr-current-current", 1, :complete})
    refute_received {:websocket_owner_frame, "corr-current-current", 1, _duplicate}
    assert :erpc.call(owner_peer.node, Process, :alive?, [owner])
    assert_owner_idle(owner_peer.node, session.id, owner)
    assert_no_external_network([proxy, owner_peer])
  end

  test "unknown v2 rejects before owner lookup or work and preserves function-free remote terms" do
    caller = start_peer!(:future_caller)
    owner_peer = start_peer!(:future_owner)
    assert :ok = Fixture.load_lookup_sentinels(owner_peer.node)

    request = owner_request(Ecto.UUID.generate(), version: 2)
    remote_terms = ["future-session", downstream("corr-future"), request]
    refute contains_function?(remote_terms)

    assert {:rpc_receipt, rpc_arguments, {:error, :owner_unavailable}} =
             :erpc.call(caller.node, Fixture, :call_current_v1, [
               owner_peer.node,
               "future-session",
               downstream("corr-future"),
               request,
               @peer_timeout
             ])

    refute contains_function?(rpc_arguments)
    assert %{identity: 0, owner: 0} = Fixture.lookup_sentinel_counts(owner_peer.node)
    assert_no_forbidden_work()
    assert_no_external_network([caller, owner_peer])
  end

  test "peer cleanup runs after a forced assertion failure" do
    peer_name = String.to_atom("forced_cleanup_#{System.unique_integer([:positive])}")

    assert {:error, %ExUnit.AssertionError{}} =
             Fixture.run_forced_failure_cleanup_probe(peer_name)

    assert_peer_absent!(peer_name)
  end

  defp start_peer!(prefix) do
    peer_name = String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

    assert {:ok, peer_pid, peer_node} =
             :peer.start_link(%{
               name: peer_name,
               args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
             })

    on_exit(fn ->
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
      refute peer_node in Node.list(:connected)
      assert_peer_absent!(peer_name)
    end)

    Process.unlink(peer_pid)
    assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    assert {:ok, tracer} = :erpc.call(peer_node, Fixture, :start_external_network_guard, [])

    %{name: peer_name, pid: peer_pid, node: peer_node, tracer: tracer}
  end

  defp start_runtime!(peer_node) do
    assert {:ok, runtime} = :erpc.call(peer_node, Fixture, :start_runtime, [])
    assert node(runtime) == peer_node
    runtime
  end

  defp start_owner!(peer_node, session, terminal_messages \\ []) do
    assert {:ok, owner} =
             :erpc.call(peer_node, Fixture, :start_owner, [session, self(), terminal_messages])

    owner
  end

  defp attach!(peer_node, session_id, correlation_id) do
    assert {:ok, attached} =
             :erpc.call(peer_node, WebsocketOwnerForwarder, :remote_attach_downstream, [
               session_id,
               downstream(correlation_id)
             ])

    attached
  end

  defp assert_owner_idle(peer_node, session_id, owner) do
    assert {:ok, ^owner} = :erpc.call(peer_node, WebsocketOwnerSession, :lookup, [session_id])
    state = :erpc.call(peer_node, :sys, :get_state, [owner])
    assert state.active_turn == nil
  end

  defp assert_no_forbidden_work do
    refute_received {:previous_release_callback_invoked, _label}
    refute_received {:mixed_release_upstream_send, _owner}
    refute_received {:mixed_release_request_materialized, _url}
    refute_received {:external_network_call, _, _, _, _}
  end

  defp assert_exactly_once(message) do
    assert_receive ^message, @peer_timeout
    refute_received ^message
  end

  defp assert_no_external_network(peers) do
    Enum.each(peers, fn peer ->
      assert {:ok, 0} =
               :erpc.call(peer.node, Fixture, :flush_external_network_guard, [peer.tracer])
    end)

    refute_received {:external_network_call, _, _, _, _}
  end

  defp assert_peer_absent!(peer_name) do
    assert {:ok, names} = :erl_epmd.names()
    refute Enum.any?(names, fn {name, _port} -> name == Atom.to_charlist(peer_name) end)
  end

  defp owner_request(identity_id, opts) do
    request = %WebsocketOwnerRequest{
      version: Keyword.fetch!(opts, :version),
      url: "https://upstream.example.test/backend-api/codex/responses",
      headers: [],
      payload: "fixture-payload",
      timeouts: %TimeoutConfig{
        connect_timeout_ms: 1_000,
        pool_timeout_ms: 1_000,
        receive_timeout_ms: 1_000
      },
      mapper: :codex_responses,
      upstream_identity_id: identity_id,
      observation: %{
        request_id: nil,
        client_request_id: nil,
        attempt_id: nil,
        mode: "full"
      },
      reset_probe: nil,
      native_codex_response_control: nil,
      assignment_advertised?: false,
      connection_bound_continuation?: false,
      forward_error_body?: false,
      submission_notification?: Keyword.get(opts, :submission_notification?, false)
    }

    if request.version == 1, do: assert(WebsocketOwnerRequest.validate(request) == :ok)
    request
  end

  defp downstream(correlation_id), do: %{pid: self(), epoch: 1, correlation_id: correlation_id}

  defp owner_session_fixture(auth, owner_node, suffix) do
    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state:
                 "mixed-release-#{suffix}-#{System.unique_integer([:positive])}",
               owner_instance_id: Atom.to_string(owner_node)
             })

    session = Repo.get!(CodexSession, session.id)
    %{session: session, token: session.owner_lease_token}
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp contains_function?(value) when is_function(value), do: true
  defp contains_function?(%_{} = value), do: value |> Map.from_struct() |> contains_function?()

  defp contains_function?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} -> contains_function?(key) or contains_function?(nested) end)
  end

  defp contains_function?(value) when is_list(value), do: Enum.any?(value, &contains_function?/1)

  defp contains_function?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_function?()

  defp contains_function?(_value), do: false

  defp ensure_distribution_started!, do: start_distribution!(node())

  defp start_distribution!(:nonode@nohost) do
    previous = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
    Application.put_env(:kernel, :prevent_overlapping_partitions, false)
    name = String.to_atom("mixed_release_test_#{System.unique_integer([:positive])}")
    assert {:ok, _pid} = :net_kernel.start([name, :shortnames])

    on_exit(fn ->
      assert :ok = :net_kernel.stop()

      case previous do
        {:ok, value} -> Application.put_env(:kernel, :prevent_overlapping_partitions, value)
        :error -> Application.delete_env(:kernel, :prevent_overlapping_partitions)
      end
    end)
  end

  defp start_distribution!(_distributed), do: :ok

  defp cleanup_local_owners do
    WebsocketOwnerSession.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.each(fn session_id ->
      try do
        with {:ok, owner} <- WebsocketOwnerSession.lookup(session_id),
             true <- Process.alive?(owner) do
          GenServer.stop(owner, :shutdown, 1_000)
        end
      catch
        :exit, _reason -> :ok
      end
    end)

    :ok
  end
end
