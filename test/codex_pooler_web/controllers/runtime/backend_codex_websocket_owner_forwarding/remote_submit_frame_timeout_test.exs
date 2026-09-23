defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.RemoteSubmitFrameTimeoutTest do
  @moduledoc """
  A `response.processed` acknowledgement reaches a remote owner through
  `WebsocketOwnerForwarder.submit_frame/5`. When the owner answers after the
  forward budget, the client is told the forward failed, but the owner still
  takes the frame it had queued. The forwarder used to follow that timeout with
  the best-effort detach a timed-out turn submission sends, which the owner
  applies after the frame: the still connected socket lost its downstream at
  the owner, and every later turn on it was refused `409 stale_owner` until the
  client reconnected (findings#206 row 206-276).
  """

  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

  @detection_timeout_ms 15_000

  defmodule ShortFrameBudgetNodeClient do
    @moduledoc false
    # Every remote owner call runs through the production erpc client against
    # the local node, so an expired budget is `{:erpc, :timeout}` exactly as
    # between two nodes. Only the frame forward gets a short budget; the owner
    # is held suspended past it, so its length decides nothing but test time.
    @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

    alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.ERPCNodeClient
    alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient

    @frame_budget_ms 200

    @impl true
    defdelegate connected_app_nodes, to: ReplayRemoteNodeClient

    @impl true
    defdelegate app_node?(node), to: ReplayRemoteNodeClient

    @impl true
    def call_owner(remote_node, module, function, args, timeout) do
      budget = if function == :remote_submit_frame, do: @frame_budget_ms, else: timeout
      send(:persistent_term.get({ReplayRemoteNodeClient, :state}).notify, {:short_frame_remote_call, remote_node, function})
      ERPCNodeClient.call_owner(node(), module, function, args, budget)
    end
  end

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  test "a response.processed forward the remote owner answers late keeps the socket's downstream attached" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_remote_frame_timeout",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 2, "total_tokens" => 4}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-remote-frame-timeout", Ecto.UUID.generate())
    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    remote_node = :"codex_pooler@remote-frame-timeout.example"
    ReplayRemoteNodeClient.configure(remote_node, self())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      state.codex_session
      |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
      |> Repo.update!()

    active_owner_lease(session.id)
    |> Ecto.Changeset.change(owner_instance_id: Atom.to_string(remote_node), updated_at: now)
    |> Repo.update!()

    :sys.replace_state(owner_pid, fn owner_state -> %{owner_state | owner_instance_id: Atom.to_string(remote_node)} end)
    state = state |> remote_owner_state(remote_node, node_client: ShortFrameBudgetNodeClient) |> Map.put(:codex_session, session)

    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote frame timeout first"), [opcode: :text]}, state)
    {pushes, state} = drive_until_done(state)
    assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_frame_timeout"))
    attached = :sys.get_state(owner_pid).downstream
    assert %{pid: socket_pid} = attached
    assert socket_pid == self()

    processed =
      CodexPooler.JSON.encode!(%{
        "type" => "response.processed",
        "response_id" => "resp_remote_frame_timeout",
        "request_id" => "ws-remote-frame-timeout-processed"
      })

    # The owner stalls past the forward budget: the socket's forward times out
    # and its task ends while the owner still holds the queued frame.
    :ok = :sys.suspend(owner_pid)

    {pushes, state} =
      try do
        assert {:ok, state} = CodexResponsesSocket.handle_in({processed, [opcode: :text]}, state)
        assert_receive {:short_frame_remote_call, ^remote_node, :remote_submit_frame}, @detection_timeout_ms
        drive_until_done(state)
      after
        :ok = :sys.resume(owner_pid)
      end

    assert [error_frame] = pushes
    assert %{"status" => 502, "error" => %{"code" => "upstream_websocket_forward_failed"}} = CodexPooler.JSON.decode!(error_frame)
    assert CodexPooler.JSON.decode!(error_frame)["error"]["message"] =~ "owner_forward_timeout"

    # Ordered behind every call the stalled owner had queued.
    assert %{downstream: ^attached} = :sys.get_state(owner_pid)

    assert {:ok, state} = CodexResponsesSocket.handle_in({websocket_payload(setup, "remote frame timeout second"), [opcode: :text]}, state)
    {pushes, state} = drive_until_done(state)
    assert Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["id"] == "resp_remote_frame_timeout"))
    refute Enum.any?(pushes, &(CodexPooler.JSON.decode!(&1)["type"] == "error"))

    assert ["response.create", "response.processed", "response.create"] = Enum.map(FakeUpstream.requests(upstream), & &1.json["type"])
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  # Feeds the socket the messages a WebSock loop would, collecting pushed
  # text frames, until the response task's result and its scheduled delivery
  # completion have been handled.
  defp drive_until_done(state, pushes \\ []) do
    receive do
      {:codex_response_done, pid, _result} = message ->
        {pushes, state} = apply_socket_message(message, state, pushes)
        finish_delivery(state, pushes, pid)

      message
      when is_tuple(message) and
             elem(message, 0) in [
               :websocket_owner_frame,
               :websocket_owner_cleanup_witness,
               :websocket_owner_output_commit_probe,
               :websocket_response_activity,
               :direct_request_cleanup
             ] ->
        {pushes, state} = apply_socket_message(message, state, pushes)
        drive_until_done(state, pushes)
    after
      @detection_timeout_ms -> flunk("expected the websocket response task to finish")
    end
  end

  defp finish_delivery(state, pushes, pid) do
    receive do
      {:websocket_response_delivery_complete, ^pid, _token} = message -> apply_socket_message(message, state, pushes)
    after
      @detection_timeout_ms -> flunk("expected the scheduled delivery completion")
    end
  end

  defp apply_socket_message(message, state, pushes) do
    case CodexResponsesSocket.handle_info(message, state) do
      {:ok, state} -> {pushes, state}
      {:push, {:text, frame}, state} -> {pushes ++ [frame], state}
      other -> flunk("the socket stopped: #{inspect(elem(other, 0))}")
    end
  end
end
