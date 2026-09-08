defmodule CodexPoolerWeb.Runtime.DurableAffinityControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.FakeUpstream

  alias CodexPooler.Gateway.Persistence.{
    BridgeAffinity,
    BridgeDemotion,
    CodexSession,
    RoutingCircuitState
  }

  alias CodexPooler.Pools
  alias CodexPooler.Repo

  for failure_status <- [429, 503, :quota] do
    test "HTTP #{failure_status} failover persists across session recreation and account recovery",
         %{conn: conn} do
      a_server = start_upstream(success("a"))
      b_server = start_upstream(success("b"))
      setup = gateway_setup(a_server)
      b = gateway_upstream(setup.pool, b_server, "synthetic-b-token", [])
      prime_routing_quota!(b.identity)

      setup = %{
        setup
        | model: put_model_source_assignments!(setup.model, [setup.assignment, b.assignment])
      }

      Pools.ensure_routing_settings(setup.pool)
      |> Ecto.Changeset.change(durable_conversation_affinity_enabled: true)
      |> Repo.update!()

      payload = %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("synthetic conversation"),
        "prompt_cache_key" => "unmodified-client-cache",
        "stream" => false
      }

      assert json_response(call(conn, setup, payload, "window-a"), 200)["id"] in [
               "resp-a",
               "resp-b"
             ]

      row = Repo.one!(from a in BridgeAffinity, where: a.affinity_kind == "durable_conversation")

      {old, fallback, old_server, fallback_server} =
        if row.pool_upstream_assignment_id == setup.assignment.id,
          do: {%{assignment: setup.assignment, identity: setup.identity}, b, a_server, b_server},
          else: {b, %{assignment: setup.assignment, identity: setup.identity}, b_server, a_server}

      if unquote(failure_status) == :quota do
        prime_exhausted_routing_quota!(old.identity)
      else
        FakeUpstream.set_mode(
          old_server,
          FakeUpstream.json_response(
            %{"error" => %{"message" => "synthetic failure", "type" => "server_error"}},
            unquote(failure_status)
          )
        )
      end

      count_before_failure = FakeUpstream.count(old_server)

      assert json_response(call(conn, setup, payload, "window-b"), 200)["id"] in [
               "resp-a",
               "resp-b"
             ]

      assert Repo.reload!(row).pool_upstream_assignment_id == fallback.assignment.id

      if unquote(failure_status) == :quota do
        assert FakeUpstream.count(old_server) == count_before_failure
      else
        assert Repo.exists?(
                 from a in Attempt,
                   where:
                     a.pool_upstream_assignment_id == ^old.assignment.id and
                       a.status == "retryable_failed"
               )
      end

      expired_at = DateTime.add(DateTime.utc_now(), -120, :second)

      previous_ids =
        Repo.all(from s in CodexSession, where: s.pool_id == ^setup.pool.id, select: s.id)

      Repo.update_all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id),
        set: [owner_lease_expires_at: expired_at]
      )

      FakeUpstream.set_mode(old_server, success("recovered"))

      Repo.reload!(old.assignment)
      |> Ecto.Changeset.change(health_status: "active", cooldown_until: nil)
      |> Repo.update!()

      Repo.delete_all(from d in BridgeDemotion, where: d.pool_id == ^setup.pool.id)
      Repo.delete_all(from c in RoutingCircuitState, where: c.pool_id == ^setup.pool.id)
      prime_routing_quota!(old.identity)
      count_old = FakeUpstream.count(old_server)
      count_fallback = FakeUpstream.count(fallback_server)

      assert json_response(call(conn, setup, payload, "window-b"), 200)["id"] in [
               "resp-a",
               "resp-b"
             ]

      assert FakeUpstream.count(old_server) == count_old
      assert FakeUpstream.count(fallback_server) == count_fallback + 1

      assert Repo.exists?(
               from s in CodexSession,
                 where: s.pool_id == ^setup.pool.id and s.id not in ^previous_ids
             )

      for request <- FakeUpstream.requests(a_server) ++ FakeUpstream.requests(b_server) do
        assert request.json["prompt_cache_key"] == payload["prompt_cache_key"]
      end
    end
  end

  defp call(conn, setup, payload, window) do
    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("thread-id", "synthetic-thread")
    |> put_req_header("session-id", "root-session")
    |> put_req_header("x-codex-window-id", window)
    |> post("/backend-api/codex/responses", payload)
  end

  defp success(account) do
    FakeUpstream.json_response(%{
      "id" => "resp-#{account}",
      "object" => "response",
      "status" => "completed",
      "output" => [],
      "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
    })
  end
end
