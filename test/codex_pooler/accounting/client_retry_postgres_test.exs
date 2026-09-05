defmodule CodexPooler.Accounting.ClientRetryPostgresTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request, RequestClientRetryLink}
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000

  test "committed retry cleanup removes its identity and pricing without touching another fixture" do
    Sandbox.unboxed_run(Repo, fn ->
      fixture = committed_fixture()
      other = committed_fixture()

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          cleanup_fixture(fixture)
          cleanup_fixture(other)
        end)
      end)

      cleanup_fixture(fixture)

      refute Repo.get(CodexPooler.Upstreams.Schemas.UpstreamIdentity, fixture.identity_id)
      refute Repo.get(CodexPooler.Catalog.PricingSnapshot, fixture.pricing_id)
      assert Repo.get!(Pool, other.pool_id)
      assert Repo.get!(CodexPooler.Upstreams.Schemas.UpstreamIdentity, other.identity_id)
      assert Repo.get!(CodexPooler.Catalog.PricingSnapshot, other.pricing_id)
      cleanup_fixture(fixture)
    end)
  end

  test "two committed PostgreSQL backends race to one successor lifecycle" do
    fixture = Sandbox.unboxed_run(Repo, &committed_fixture/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        cleanup_fixture(fixture)
      end)
    end)

    parent = self()
    release = make_ref()

    tasks =
      for lane <- [:first, :second] do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:backend_ready, lane, backend_pid, self()})

            receive do
              {:release, ^release} ->
                Accounting.claim_client_retry_successor(
                  fixture.auth,
                  fixture.model,
                  fixture.payload,
                  fixture.opts
                )
            end
          end)
        end)
      end

    ready =
      for _lane <- 1..2 do
        assert_receive {:backend_ready, lane, backend_pid, task_pid}, @detection_budget
        {lane, backend_pid, task_pid}
      end

    assert ready |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 2
    Enum.each(ready, fn {_lane, _backend, task_pid} -> send(task_pid, {:release, release}) end)

    results = Enum.map(tasks, &Task.await(&1, @detection_budget))
    assert Enum.count(results, &match?({:ok, %ClientRetry.SuccessorClaim{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :successor_claimed}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(RequestClientRetryLink, :count) == 1
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^fixture.pool_id), :count) == 2

      assert Repo.aggregate(
               from(t in CodexTurn, where: t.codex_session_id == ^fixture.session_id),
               :count
             ) == 2

      assert Repo.aggregate(
               from(a in Attempt, where: a.request_id == ^fixture.predecessor_id),
               :count
             ) == 1

      successor_id = Repo.one!(from l in RequestClientRetryLink, select: l.successor_request_id)
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^successor_id), :count) == 0
    end)
  end

  defp cleanup_fixture(fixture) do
    Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool_id)

    Repo.delete_all(
      from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
        where: identity.id == ^fixture.identity_id
    )

    Repo.delete_all(
      from pricing in CodexPooler.Catalog.PricingSnapshot,
        where: pricing.id == ^fixture.pricing_id
    )
  end

  defp committed_fixture do
    setup = accounting_setup(%{price_version: unique_price_version()})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    digest = :crypto.strong_rand_bytes(32)
    semantic_digest = :crypto.strong_rand_bytes(32)
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: predecessor}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: Ecto.UUID.generate(),
        native_client_retry_witness: witness
      })

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: "retry-pg-#{System.unique_integer([:positive, :monotonic])}",
        pool_upstream_assignment_id: setup.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      })

    turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: predecessor.id,
        turn_sequence: 1,
        transport_kind: "websocket",
        semantic_turn_digest: semantic_digest,
        status: "failed",
        error_code: "upstream_stream_error",
        first_visible_output_at: now,
        completed_at: now,
        started_at: now,
        created_at: now,
        updated_at: now
      })

    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(predecessor, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "upstream_stream_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        replay_generation: 0,
        response_metadata: eligible_metadata(now)
      })

    Repo.update!(
      Ecto.Changeset.change(predecessor,
        status: "failed",
        usage_status: "usage_unknown",
        completed_at: now,
        last_error_code: "upstream_stream_error"
      )
    )

    Repo.update!(Ecto.Changeset.change(turn, final_attempt_id: attempt.id))

    %{
      auth: setup.auth,
      model: setup.model,
      identity_id: setup.identity.id,
      pricing_id: setup.pricing.id,
      payload: %{"model" => setup.model.exposed_model_id, "input" => []},
      pool_id: setup.pool.id,
      session_id: session.id,
      predecessor_id: predecessor.id,
      opts: %{
        endpoint: "/backend-api/codex/responses",
        requested_model: setup.model.exposed_model_id,
        runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
        codex_session: session,
        semantic_turn_digest: semantic_digest,
        replay_claim_digest: digest
      }
    }
  end

  defp eligible_metadata(now) do
    %{
      "transport_failure" => %{
        "phase" => "receive",
        "termination_source" => "peer_close_frame",
        "transport_signal" => "tcp_closed"
      },
      "native_client_retry_observation" => %{
        "version" => 1,
        "authority_complete" => true,
        "output_item_done_count" => 0,
        "output_item_done_count_saturated" => false,
        "partial_reasoning_seen" => true,
        "first_visible_at" => DateTime.to_iso8601(now),
        "terminal_seen" => false,
        "terminal_candidate_seen" => false
      }
    }
  end

  defp unique_price_version,
    do: "t10-pg-#{System.unique_integer([:positive, :monotonic])}"
end
