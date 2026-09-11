defmodule CodexPooler.Accounting.FailedPredecessorResendLockOrderTest do
  @moduledoc """
  Real-PostgreSQL proof that the websocket failed-predecessor resend claim
  locks the codex session before `api_keys`, the order every other runtime
  path takes (an HTTP reservation locks the session and then authorizes the
  key). The inverted claim held `api_keys` while waiting on the session a
  reservation already held, and PostgreSQL aborted one of them as a deadlock
  after `deadlock_timeout`.
  """

  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestLifecycle.Reservation
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint "/backend-api/codex/responses"
  @barrier_key {Reservation, :runtime_authorization_barrier}
  @detection_budget_ms 15_000

  @tag timeout: 60_000
  test "the resend claim locks the session before api_keys so a session-first reservation serializes" do
    fixture = unboxed_resend_fixture()
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end) end)

    parent = self()
    ref = make_ref()

    resend =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(@barrier_key, {parent, ref, {:claim, :after}})
          send(parent, {:resend_ready, ref, backend_pid!()})

          safely(fn ->
            Accounting.claim_websocket_turn(fixture.auth, fixture.model, fixture.opts)
          end)
        end)
      end)

    assert_receive {:resend_ready, ^ref, resend_backend}, @detection_budget_ms

    # The first claim transaction meets the correlation constraint of the failed
    # predecessor and rolls back; the second one is the resend claim.
    assert_receive {:runtime_authorization_barrier, ^ref, :claim, :after, resend_pid},
                   @detection_budget_ms

    send(resend_pid, {:runtime_authorization_release, ref})

    # The resend claim now holds every row it locked through key authorization.
    assert_receive {:runtime_authorization_barrier, ^ref, :claim, :after, ^resend_pid},
                   @detection_budget_ms

    reservation =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, {:reservation_ready, ref, backend_pid!()})

          safely(fn ->
            Repo.transaction(fn ->
              _session =
                Repo.one!(
                  from session in CodexSession,
                    where: session.id == ^fixture.session_id,
                    lock: "FOR UPDATE"
                )

              _api_key =
                Repo.one!(
                  from api_key in APIKey,
                    where: api_key.id == ^fixture.api_key_id,
                    lock: "FOR UPDATE"
                )

              :reserved
            end)
          end)
        end)
      end)

    assert_receive {:reservation_ready, ^ref, reservation_backend}, @detection_budget_ms
    blocked_relation = await_block!(reservation_backend, resend_backend)

    send(resend_pid, {:runtime_authorization_release, ref})

    resend_result = Task.await(resend, @detection_budget_ms)
    reservation_result = Task.await(reservation, @detection_budget_ms)

    refute {:error, {:postgres, :deadlock_detected}} in [resend_result, reservation_result],
           "lock-order deadlock: resend=#{inspect(summarize(resend_result))} " <>
             "reservation=#{inspect(summarize(reservation_result))} " <>
             "blocked_on=#{blocked_relation}"

    predecessor_id = fixture.predecessor_id

    assert {:ok,
            {:ok,
             %{
               request: %Request{id: resend_id},
               client_resend: %{predecessor_request_id: ^predecessor_id}
             }}} = resend_result

    assert {:ok, {:ok, :reserved}} = reservation_result

    # The session-first transaction waited on the session, never on the key: the
    # resend claim had already taken the session row before authorizing the key.
    assert blocked_relation == "codex_sessions"

    persisted =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.all(
          from request in Request,
            where: request.pool_id == ^fixture.auth.pool.id,
            order_by: [asc: request.admitted_at],
            select: request.id
        )
      end)

    assert persisted == [predecessor_id, resend_id]
  end

  defp await_block!(waiter_backend, blocker_backend) do
    await_block!(
      waiter_backend,
      blocker_backend,
      System.monotonic_time(:millisecond) + @detection_budget_ms
    )
  end

  defp await_block!(waiter_backend, blocker_backend, deadline) do
    observation =
      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(
          Repo,
          "SELECT query FROM pg_stat_activity WHERE pid = $1 AND $2 = ANY(pg_blocking_pids(pid))",
          [waiter_backend, blocker_backend]
        ).rows
      end)

    case observation do
      [[query] | _rest] ->
        case Regex.run(~r/FROM "(\w+)"/, query) do
          [_match, relation] -> relation
          nil -> flunk("blocked statement did not name a relation")
        end

      [] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("session-first transaction never blocked on the resend claim")
        else
          # Polls PostgreSQL's own lock-wait view; the barrier, not this interval,
          # decides the ordering.
          Process.sleep(20)
          await_block!(waiter_backend, blocker_backend, deadline)
        end
    end
  end

  defp unboxed_resend_fixture do
    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture()
      pool = pool_fixture(%{created_by_user_id: owner.id})
      %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
      auth = %{pool: pool, api_key: api_key}
      model = model_fixture(pool)
      %{assignment: assignment} = upstream_assignment_fixture(pool)
      suffix = System.unique_integer([:positive, :monotonic])
      now = db_now()

      session =
        Repo.insert!(%CodexSession{
          pool_id: pool.id,
          api_key_id: api_key.id,
          session_key: "resend-lock-order-#{suffix}",
          pool_upstream_assignment_id: assignment.id,
          status: "active",
          created_at: now,
          updated_at: now
        })

      opts = %{
        endpoint: @endpoint,
        correlation_id:
          "codex-request:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        codex_session: session,
        request_metadata: %{"request_id" => "resend-lock-order-#{suffix}"}
      }

      assert {:ok, %{request: predecessor}} = Accounting.claim_websocket_turn(auth, model, opts)
      fail_predecessor!(assignment, session, predecessor)

      %{
        auth: auth,
        model: model,
        opts: opts,
        session_id: session.id,
        api_key_id: api_key.id,
        predecessor_id: predecessor.id
      }
    end)
  end

  # A provider-terminal failure inside the retry window: the one shape the
  # resend claim admits without further cut evidence.
  defp fail_predecessor!(assignment, session, request) do
    now = db_now()

    attempt =
      attempt_fixture(request, assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "server_error",
        transport: "websocket",
        usage_status: "usage_unknown",
        response_metadata: %{
          "stream_terminal_type" => "response.failed",
          "error_kind" => "server_error"
        }
      })

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      semantic_turn_digest: :crypto.strong_rand_bytes(32),
      status: "failed",
      error_code: "server_error",
      final_attempt_id: attempt.id,
      first_visible_output_at: now,
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: now
    })

    Repo.update!(
      Ecto.Changeset.change(request,
        status: "failed",
        usage_status: "usage_unknown",
        response_status_code: 200,
        last_error_code: "server_error",
        completed_at: now
      )
    )
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp summarize({:ok, {:ok, %{request: %Request{status: status}}}}),
    do: {:ok, {:request, status}}

  defp summarize(result), do: result

  defp safely(operation) do
    {:ok, operation.()}
  rescue
    error in Postgrex.Error -> {:error, {:postgres, error.postgres && error.postgres.code}}
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end
end
