defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.DatabaseUnavailableTest do
  # A websocket turn claims its request row before the reservation transaction,
  # outside the rescue that answers a transient database failure with a
  # retryable 503 (findings#206 row 206-358). A database that stopped answering
  # there made the response task raise, and the client got `500
  # websocket_response_task_failed` from a task logged as failed
  # (`owner_task_exception`). The claim now gets the same 503 before anything is
  # reserved or sent, and the client's resend is served once the database is
  # back (findings#206 row 206-368). One node, websocket, with owner forwarding
  # on and off.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @response_id "resp_database_unavailable_resend"

  for forwarding <- [:owner_forwarding, :direct] do
    @tag forwarding: forwarding
    test "a turn claim cut by a database shutdown answers a retryable 503 event and the resend is served (#{forwarding})", %{forwarding: forwarding} do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :owner_forwarding)

      upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, completed_frames(@response_id))]))
      setup = gateway_setup(upstream)
      {_server, port} = start_public_endpoint_with_server!()
      {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())

      # PostgreSQL ends in-flight statements with `57P01 admin_shutdown` when the
      # instance stops. The trigger raises it from the claim's insert, inside the
      # sandbox transaction every process of this test shares.
      Repo.query!("CREATE FUNCTION pg_temp.p80_claim_shutdown() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'terminating connection due to administrator command' USING ERRCODE = 'admin_shutdown'; END $$")
      Repo.query!("CREATE TRIGGER p80_claim_shutdown BEFORE INSERT ON requests FOR EACH ROW EXECUTE FUNCTION pg_temp.p80_claim_shutdown()")

      frame = frame(setup)

      {{conn, websocket, refused}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
          receive_until_terminal(conn, websocket, ref)
        end)

      assert %{
               "type" => "error",
               "status" => 503,
               "error" => %{"type" => "server_error", "code" => "service_unavailable", "message" => "Codex Pooler is temporarily unavailable; retry the request"}
             } = refused

      assert log =~ "runtime request refused before dispatch stage=turn_claim reason_class=postgres_admin_shutdown"
      refute log =~ "websocket response task failed"
      refute log =~ "administrator command"
      refute CodexPooler.JSON.encode!(refused) =~ ~r/(?i)postgres|dbconnection|administrator/
      assert FakeUpstream.count(upstream) == 0
      assert pool_requests(setup.pool.id) == []
      assert Repo.aggregate(from(l in LedgerEntry, where: l.pool_id == ^setup.pool.id), :count) == 0

      # The database is back; the same frame on the same socket is served once.
      Repo.query!("DROP TRIGGER p80_claim_shutdown ON requests")
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      {conn, _websocket, terminal} = receive_until_terminal(conn, websocket, ref)
      Mint.HTTP.close(conn)

      assert %{"type" => "response.completed"} = terminal
      assert FakeUpstream.count(upstream) == 1
      assert [%Request{transport: "websocket"}] = pool_requests(setup.pool.id)
    end
  end

  # The released client names the thread and the turn in `client_metadata`
  # (Codex rust-v0.156.0), which gives the frame its durable turn claim.
  defp frame(setup) do
    thread_id = setup.pool.id

    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("synthetic turn"),
      "stream" => true,
      "generate" => true,
      "client_metadata" => %{
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "database-unavailable-turn", "request_kind" => "turn"})
      }
    })
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}}
      })
    ])
  end

  defp pool_requests(pool_id) do
    Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at, asc: r.id]))
  end

  defp receive_until_terminal(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] ->
        {conn, websocket, terminal}

      %{"type" => _type} ->
        receive_until_terminal(conn, websocket, ref)
    end
  end
end
