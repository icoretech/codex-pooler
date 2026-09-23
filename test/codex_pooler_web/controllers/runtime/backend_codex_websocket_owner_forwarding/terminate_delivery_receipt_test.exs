defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.TerminateDeliveryReceiptTest do
  # A socket that closes while its response task is still running acknowledges
  # the task during terminate and then drains it. The task consumes the first
  # acknowledgement it receives, and the socket pushed at most one terminal, so
  # the turn gets exactly one delivery receipt: the drain must not acknowledge
  # and record the same task a second time (findings#225, row 225-100, where
  # production logged `aborted` then `delivered` for one request).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag capture_log: true

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  @tag slow: "terminates a real owner-forwarded socket under a running turn and waits for its owner-side task to settle (0.7 s alone, 1.04 s under partition load)"
  test "a socket closing under a running turn records one delivery receipt for it" do
    release_ref = make_ref()
    upstream_boundary = blocking_owner_upstream_boundary(self(), release_ref)
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      owner_socket(auth, "ws-owner-terminate-receipt", "ws-owner-terminate-receipt", websocket_owner_forwarder_opts: [upstream: upstream_boundary])

    payload = turn_payload(setup, "ws-owner-terminate-receipt-turn", "a turn still running at close")
    assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
    _worker = assert_blocking_owner_upstream_received!(release_ref)

    {:ok, owner_pid} = WebsocketOwnerSession.lookup(state.codex_session.id)
    Sandbox.allow(Repo, self(), owner_pid)

    {result, log} = with_info_log(fn -> CodexResponsesSocket.terminate(:closed, state) end)
    assert result == :ok

    [request] = request_logs(setup.pool.id)
    receipts = Regex.scan(~r/websocket downstream terminal pushed request_id=#{request.id} [^\n]*/, log)

    assert length(receipts) == 1, "expected one delivery receipt, got #{length(receipts)}"
    assert [[receipt]] = receipts
    assert receipt =~ "outcome=aborted"

    [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.response_metadata["downstream_delivery"]["outcome"] == "aborted"

    await_owner_cleanup!(state.codex_session.id)
  end

  defp turn_payload(setup, turn_id, content) do
    websocket_payload(setup, content, %{
      "request_id" => turn_id,
      "client_metadata" => %{
        "turn_id" => turn_id,
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"turn_id" => turn_id, "request_kind" => "turn"})
      }
    })
  end
end
