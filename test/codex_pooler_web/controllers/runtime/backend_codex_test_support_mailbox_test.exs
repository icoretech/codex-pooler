defmodule CodexPoolerWeb.Runtime.BackendCodexTestSupportMailboxTest do
  @moduledoc """
  The public websocket receive helpers take only the messages Mint delivers for
  their own connection's socket. They used to take any message and drop what
  Mint called `:unknown`, which ate a fake upstream's ping notices and, in
  Drone 1513, the `:DOWN` of the Bandit connection a test monitored while it
  waited for the close frame (`handshake_test.exs`, fragmented message above
  the body cap). Each test puts a foreign message in the mailbox before the
  helper runs; the helper must leave it there.
  """

  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings

  @detection_timeout_ms 15_000

  test "the upgrade and text helpers leave the test's other messages in its mailbox" do
    completed = %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_mailbox_helper", "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}
    }

    upstream = start_upstream(FakeUpstream.sse_stream([{"response.completed", completed}]))
    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    marker = make_ref()

    send(self(), {:foreign_before_upgrade, marker})
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "mailbox-helper-#{System.unique_integer([:positive])}")

    try do
      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("mailbox helper"),
          "stream" => true,
          "generate" => true
        })

      send(self(), {:foreign_before_frame, marker})
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {_conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(frame)
      assert_received {:foreign_before_upgrade, ^marker}
      assert_received {:foreign_before_frame, ^marker}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "the close helper leaves the monitored connection's DOWN in the mailbox" do
    previous = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, %OperationalSettings{max_decompressed_body_bytes: 700, websocket_idle_timeout_ms: 60_000})
      |> Keyword.put(:use_instance_settings?, false)
    )

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unused_mailbox_helper"}))
    setup = gateway_setup(upstream)
    {server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "mailbox-close-#{System.unique_integer([:positive])}")

    try do
      assert {:ok, [connection_pid]} = ThousandIsland.connection_pids(server)
      monitor_ref = Process.monitor(connection_pid)
      marker = make_ref()

      {{_conn, _websocket, code, _reason}, _logs} =
        ExUnit.CaptureLog.with_log(fn ->
          send(self(), {:foreign_before_close, marker})
          {conn, websocket} = public_websocket_send_fragmented_text!(conn, websocket, ref, String.duplicate("x", 400), String.duplicate("x", 400))
          result = public_websocket_receive_close!(conn, websocket, ref)
          assert_receive {:DOWN, ^monitor_ref, :process, ^connection_pid, _reason}, @detection_timeout_ms
          result
        end)

      assert code == 1009
      assert_received {:foreign_before_close, ^marker}
    after
      Mint.HTTP.close(conn)
    end
  end
end
