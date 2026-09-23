defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeTakeoverContinuityTest do
  # A websocket-bridged public `/v1/responses` turn whose session is owned by
  # another, unreachable instance with a live lease (for example after the
  # other pod served an HTTP compaction, findings#225 row 225-99) takes the
  # owner lease over and is served. Its continuity must then be registered
  # under the lease it took: the request's HTTP owner witness still named the
  # replaced lease, so `gateway continuity registration failed ...
  # reason_code=stale_owner` fired and the turn's response id never became a
  # `previous_response_id` alias (findings#225 row 225-102, seen on D2's `/v1`
  # compaction-item replay; the replayed compaction item is not the cause).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession}
  alias CodexPooler.Repo

  @remote_owner "unreachable-owner@nohost"

  setup do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)

    :ok
  end

  for replay? <- [true, false] do
    @tag replay_compaction_item: replay?
    test "a bridged turn that took the owner lease over registers its continuity (compaction item replayed: #{replay?})", %{conn: conn, replay_compaction_item: replay?} do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.compaction_stream(compaction_response())),
            bridged_turn("resp_takeover_continuity_after"),
            bridged_turn("resp_takeover_continuity_next")
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      session_key = "takeover-continuity-#{System.unique_integer([:positive])}"
      message = %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic takeover continuity"}]}
      compaction_item = %{"type" => "compaction", "id" => "cmp_takeover0123456789", "encrypted_content" => "synthetic-takeover-encrypted"}

      assert post_stream(conn, setup, [message, %{"type" => "compaction_trigger"}], session_key).status == 200
      session = move_owner_to_unreachable_instance!(setup)

      input = if replay?, do: [compaction_item, message], else: [message]

      log =
        capture_log([level: :warning], fn ->
          response = post_stream(conn, setup, input, session_key)
          assert response.status == 200
          assert response.resp_body =~ "resp_takeover_continuity_after"
        end)

      refute log =~ "continuity registration failed"

      # The bridged request took the lease over on this node.
      assert %CodexSession{owner_instance_id: owner} = Repo.get!(CodexSession, session.id)
      assert owner == Atom.to_string(node())
      assert [%BridgeOwnerLease{metadata: %{"source" => "owner_unavailable_takeover"}}] = active_leases(session)

      # Its response id is an alias of the session: a tool-output continuation
      # that names only that response (no session header) lands on the same
      # session.
      tool_output = %{"type" => "function_call_output", "call_id" => "call_takeover_continuity", "output" => "synthetic tool output"}
      response = post_stream(conn, setup, [tool_output], nil, %{"previous_response_id" => "resp_takeover_continuity_after"})
      assert response.status == 200, response.resp_body
      assert %Request{} = continuation = latest_request(setup)
      assert continuation.request_metadata["codex_session_id"] == session.id
    end
  end

  defp compaction_response do
    %{
      "id" => "resp_takeover_continuity_compact",
      "object" => "response.compaction",
      "output" => [%{"type" => "compaction", "id" => "cmp_takeover0123456789", "encrypted_content" => "synthetic-takeover-encrypted"}],
      "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
    }
  end

  defp bridged_turn(response_id) do
    completed = %{"type" => "response.completed", "response" => %{"id" => response_id, "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}

    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      json: [valid: true, equals: %{"type" => "response.create"}],
      respond: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(completed)])
    )
  end

  defp post_stream(conn, setup, input, session_key, extra \\ %{}) do
    conn = conn |> recycle() |> auth(setup)
    conn = if session_key, do: put_req_header(conn, "x-session-id", session_key), else: conn
    post(conn, "/v1/responses", Map.merge(%{"model" => setup.model.exposed_model_id, "input" => input, "stream" => true}, extra))
  end

  # The session's owner becomes another instance holding a live lease, the
  # state the other pod leaves after serving the session over HTTP.
  defp move_owner_to_unreachable_instance!(setup) do
    [session] = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    deadline = DateTime.add(now, 90, :second)
    token = Ecto.UUID.generate()

    session
    |> Ecto.Changeset.change(%{owner_instance_id: @remote_owner, owner_lease_token: token, owner_lease_expires_at: deadline, last_heartbeat_at: deadline})
    |> Repo.update!()

    [lease] = active_leases(session)

    lease
    |> Ecto.Changeset.change(%{owner_instance_id: @remote_owner, lease_token: token, renewed_at: deadline, expires_at: deadline})
    |> Repo.update!()

    session
  end

  defp active_leases(session), do: Repo.all(from(l in BridgeOwnerLease, where: l.codex_session_id == ^session.id and l.status == "active"))

  defp latest_request(setup) do
    Repo.one!(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [desc: r.admitted_at], limit: 1))
  end
end
