defmodule CodexPooler.Gateway.Runtime.HttpOwnerLeaseIntegrationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.{Access, FakeUpstream, Gateway, Repo}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, SessionContinuity}

  @endpoint "/backend-api/codex/responses"
  @response %{
    "id" => "resp_lease",
    "output" => [],
    "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
  }

  test "real HTTP request retains the session beyond TTL while waiting for response headers" do
    ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_json_response(@response, notify: self(), release_ref: ref)
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup, false)
    opts = options(payload)

    task = Task.async(fn -> Gateway.execute(auth, @endpoint, payload, opts) end)
    assert_receive {:fake_upstream_timeout_barrier, :before_headers, handler, ^ref}, 5_000

    try do
      session = Repo.one!(CodexSession)
      Process.sleep(1_250)
      assert_active(session)
      assert {:ok, attached} = SessionContinuity.start_codex_session(auth, opts)
      assert attached.id == session.id
      send(handler, {:fake_upstream_release_timeout, ref})
      assert {:ok, %{status: 200}} = Task.await(task, 5_000)
      assert Repo.reload!(session).pool_upstream_assignment_id == setup.assignment.id
      assert_same_key_reconnect(auth, opts, session, setup.assignment.id)
    after
      send(handler, {:fake_upstream_release_timeout, ref})
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "real HTTP SSE keeps the owner through a silent interval and terminal finalization", %{
    conn: conn
  } do
    ref = make_ref()

    events = [
      %{"type" => "response.created", "response" => %{"id" => "resp_lease"}},
      %{"type" => "response.completed", "response" => @response}
    ]

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(events,
          notify: self(),
          release_ref: ref,
          barrier_after: 1,
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup, true)
    opts = options(payload)
    parent = self()

    task =
      Task.async(fn ->
        {:ok, %{stream: stream}} = Gateway.execute(auth, @endpoint, payload, opts)
        send(parent, :stream_returned)
        stream.(Plug.Conn.send_chunked(conn, 200))
      end)

    assert_receive {:fake_upstream_chunk_barrier, 1, handler, ^ref}, 5_000

    try do
      assert_receive :stream_returned, 5_000
      session = Repo.one!(CodexSession)
      Process.sleep(1_250)
      assert_active(session)
      send(handler, {:fake_upstream_release_chunk, ref})
      assert {:ok, _conn} = Task.await(task, 5_000)
      assert Repo.reload!(session).pool_upstream_assignment_id == setup.assignment.id
      assert_same_key_reconnect(auth, opts, session, setup.assignment.id)
    after
      send(handler, {:fake_upstream_release_chunk, ref})
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp assert_active(session) do
    assert :ok = SessionContinuity.validate_owner_token(session, session.owner_lease_token)
    current = Repo.reload!(session)
    lease = Repo.get_by!(BridgeOwnerLease, codex_session_id: session.id, status: "active")
    assert current.owner_lease_expires_at == lease.expires_at
  end

  defp assert_same_key_reconnect(auth, opts, session, assignment_id) do
    assert {:ok, next} = SessionContinuity.start_codex_session(auth, opts)
    assert next.id == session.id
    assert next.pool_upstream_assignment_id == assignment_id
    assert Repo.aggregate(CodexSession, :count) == 1
  end

  defp payload(setup, stream),
    do: %{
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "synthetic lease probe"}]
        }
      ],
      "stream" => stream
    }

  defp options(payload),
    do:
      RequestOptions.build(
        %{session_header: Ecto.UUID.generate(), bridge_owner_lease_ttl_seconds: 1},
        @endpoint,
        payload
      )
end
