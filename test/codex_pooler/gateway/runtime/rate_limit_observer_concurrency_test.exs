defmodule CodexPooler.Gateway.Runtime.RateLimitObserverConcurrencyTest do
  @moduledoc false

  # Two replay-authorized runtime rate-limit observers for one identity, on
  # independent committed backends, in the interleaving that deadlocked with the
  # row-first evidence order: observer A owns the identity advisory mutex and
  # waits on a quota window row, observer B arrives while A waits. B must wait
  # for the mutex without an identity row reference; otherwise A's later
  # `Convergence.converge/3` `FOR UPDATE` waits on B's `FOR KEY SHARE` while B
  # waits on A's mutex. Lock state is read from `pg_locks` and
  # `pg_blocking_pids` before the holder releases, as in
  # `identity_lock_order_test.exs`.

  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import CodexPooler.AccountsFixtures, only: [committed_bootstrap_owner_fixture!: 1]
  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1]
  import Ecto.Query

  alias CodexPooler.Accounting.{RequestReplay, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias Ecto.Adapters.SQL.Sandbox

  # Failure-detection budget for one wait, not a behaviour timer.
  @detection_timeout_ms 15_000

  defmodule ObserverLogRelay do
    @moduledoc false

    def log(%{msg: msg} = event, %{config: %{test_pid: test_pid}}) do
      send(test_pid, {:observer_log, message_text(msg, event)})
      :ok
    end

    defp message_text({:string, chardata}, _event), do: IO.chardata_to_string(chardata)

    defp message_text({:report, report}, _event), do: inspect(report)

    defp message_text({format, args}, _event),
      do: format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  @tag timeout: 60_000
  test "two authorized observers of one identity both commit without deadlock" do
    fixture = committed_fixture!()
    reset_at = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)

    assert :ok =
             unboxed(fn ->
               RateLimitObserver.commit_events(
                 fixture.identity,
                 %{pending_events: [rate_limits_event(40, reset_at)]},
                 nil
               )
             end)

    window_id = primary_event_window_id!(fixture.identity.id)
    attach_log_relay!()

    parent = self()
    holder = start_window_holder(parent, window_id)
    assert_receive {:holder_locked, holder_pid}, @detection_timeout_ms

    observer_a =
      start_observer(parent, :a, fixture.identity, rate_limits_event(61, reset_at), fixture.a)

    assert_receive {:observer_backend, :a, a_pid}, @detection_timeout_ms
    a_wait = await_condition(fn -> holder_pid in blocking_pids(a_pid) end)

    observer_b =
      start_observer(parent, :b, fixture.identity, rate_limits_event(73, reset_at), fixture.b)

    assert_receive {:observer_backend, :b, b_pid}, @detection_timeout_ms

    b_wait =
      await_condition(fn -> waiting_identity_advisory?(b_pid, fixture.identity.id) end)

    b_row_share_locks = upstream_identity_row_share_locks(b_pid)

    send(holder.pid, :release)
    assert :rolled_back = Task.await(holder, @detection_timeout_ms)

    a_result = Task.await(observer_a, @detection_timeout_ms)
    b_result = Task.await(observer_b, @detection_timeout_ms)
    logs = drain_logs([])

    assert a_wait == :observed, "observer A never waited on the held quota window row"
    assert b_wait == :observed, "observer B never waited on the identity advisory mutex"

    assert b_row_share_locks == 0,
           "observer B held #{b_row_share_locks} RowShareLock on upstream_identities " <>
             "while waiting for the identity advisory mutex"

    assert a_result == :ok
    assert b_result == :ok

    refute Enum.any?(logs, &(&1 =~ "gateway observer failure" or &1 =~ "deadlock")),
           "observer logged a failure: #{inspect(logs)}"

    assert %AccountQuotaWindow{used_percent: used_percent} =
             unboxed(fn -> Repo.get!(AccountQuotaWindow, window_id) end)

    assert Decimal.equal?(used_percent, Decimal.from_float(73.0))
  end

  defp start_window_holder(parent, window_id) do
    Task.async(fn -> unboxed(fn -> hold_and_roll_back(parent, window_id) end) end)
  end

  defp hold_and_roll_back(parent, window_id) do
    {:error, :rolled_back} =
      Repo.transaction(fn -> hold_window_until_release(parent, window_id) end)

    :rolled_back
  end

  # Holds FOR UPDATE on the seeded window so observer A blocks mid-transaction,
  # which is the interleaving that deadlocked under the pre-08dad3bf lock order.
  defp hold_window_until_release(parent, window_id) do
    Repo.query!("SELECT id FROM account_quota_windows WHERE id = $1 FOR UPDATE", [
      Ecto.UUID.dump!(window_id)
    ])

    %{rows: [[holder_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:holder_locked, holder_pid})

    receive do
      :release -> Repo.rollback(:rolled_back)
    end
  end

  defp start_observer(parent, label, identity, event, authority) do
    Task.async(fn ->
      unboxed(fn ->
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:observer_backend, label, backend_pid})
        RateLimitObserver.record_complete_event(identity, event, authority)
      end)
    end)
  end

  defp await_condition(condition) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_condition(condition, deadline)
  end

  defp await_condition(condition, deadline) do
    cond do
      unboxed(condition) ->
        :observed

      System.monotonic_time(:millisecond) >= deadline ->
        :not_observed

      true ->
        receive do
        after
          10 -> await_condition(condition, deadline)
        end
    end
  end

  defp blocking_pids(backend_pid) do
    %{rows: [[pids]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend_pid])
    pids
  end

  # A bigint advisory key is stored as `classid` (high 32 bits) and `objid`
  # (low 32 bits) with `objsubid = 1`.
  defp waiting_identity_advisory?(backend_pid, identity_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM pg_locks
        WHERE pid = $1
          AND NOT granted
          AND locktype = 'advisory'
          AND objsubid = 1
          AND ((classid::bigint << 32) | objid::bigint) = hashtextextended($2, 0)
        """,
        [backend_pid, identity_id]
      )

    count == 1
  end

  # `SELECT ... FOR UPDATE / FOR KEY SHARE` holds ROW SHARE on the table until
  # commit, so a granted RowShareLock is direct evidence of an identity row
  # reference.
  defp upstream_identity_row_share_locks(backend_pid) do
    unboxed(fn ->
      %{rows: [[count]]} =
        Repo.query!(
          """
          SELECT count(*)
          FROM pg_locks
          WHERE pid = $1
            AND granted
            AND locktype = 'relation'
            AND relation = 'upstream_identities'::regclass
            AND mode = 'RowShareLock'
          """,
          [backend_pid]
        )

      count
    end)
  end

  defp attach_log_relay! do
    handler_id = :"rate_limit_observer_concurrency_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(handler_id, ObserverLogRelay, %{
        level: :all,
        config: %{test_pid: self()}
      })

    on_exit(fn -> :logger.remove_handler(handler_id) end)
  end

  defp drain_logs(logs) do
    receive do
      {:observer_log, message} -> drain_logs([message | logs])
    after
      0 -> Enum.reverse(logs)
    end
  end

  defp primary_event_window_id!(identity_id) do
    unboxed(fn ->
      Repo.one!(
        from window in AccountQuotaWindow,
          where:
            window.upstream_identity_id == ^identity_id and window.quota_key == "account" and
              window.window_kind == "primary" and window.source == "codex_rate_limit_event",
          select: window.id
      )
    end)
  end

  defp rate_limits_event(used_percent, reset_at) do
    %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => used_percent,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }
  end

  # Committed equivalent of `rate_limit_observer_test.exs`'s
  # `replay_observation_fixture/0` plus `install_started_generation_one!/1`,
  # with one identity shared by two requests. The owner registers its graph
  # cleanup before committing; the Pool, its keys, sessions, requests, models,
  # assignments and the identity it holds are deleted with it. Replay
  # entitlements reference the Pool without a delete rule, so their cleanup is
  # registered after the owner's and runs before it.
  defp committed_fixture! do
    suffix = System.unique_integer([:positive, :monotonic])
    slug = "rate-limit-concurrency-#{suffix}"

    %{user: owner} =
      committed_bootstrap_owner_fixture!(%{
        "email" => "rate-limit-observer-concurrency-#{suffix}@example.com"
      })

    register_unboxed_cleanup!(fn -> delete_replay_entitlements!(slug) end)

    unboxed(fn ->
      pool = pool_fixture(%{created_by_user_id: owner.id, slug: slug})

      %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
      auth = %{pool: pool, api_key: api_key}
      %{assignment: assignment, identity: identity} = upstream_assignment_fixture(pool)

      model =
        model_fixture(pool, %{
          exposed_model_id: "gpt-rate-limit-concurrency-#{suffix}",
          metadata: %{"source_assignment_ids" => [assignment.id]}
        })

      base = %{
        api_key: api_key,
        assignment: assignment,
        auth: auth,
        identity: identity,
        model: model,
        pool: pool
      }

      %{
        identity: identity,
        a: started_generation_one_authority!(base, 1),
        b: started_generation_one_authority!(base, 2)
      }
    end)
  end

  defp started_generation_one_authority!(base, n) do
    {:ok, session} =
      Websocket.start_codex_session(base.auth, %{accepted_turn_state: Ecto.UUID.generate()})

    request =
      request_fixture(base.auth, %{
        model_id: base.model.id,
        requested_model: base.model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil
      })

    semantic_digest = <<n::256>>

    request_options =
      RequestOptions.for_websocket(%{})
      |> RequestOptions.put_continuity(semantic_turn_key: semantic_digest)

    {:ok, turn} = SessionContinuity.start_codex_turn(session, request, request_options)

    attempt =
      attempt_fixture(request, base.assignment, %{
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })
      |> Ecto.Changeset.change(%{model_id: base.model.id})
      |> Repo.update!()

    request
    |> ledger_entry_fixture(%{
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      attempt_id: nil,
      pool_upstream_assignment_id: base.assignment.id,
      upstream_identity_id: base.identity.id,
      model_id: base.model.id
    })
    |> Ecto.Changeset.change(%{source_event_id: "request:#{request.id}:reservation"})
    |> Repo.update!()

    session = Repo.reload!(session)

    {:ok, armed} =
      RequestReplay.arm(%{
        api_key_id: base.api_key.id,
        pool_id: base.pool.id,
        codex_session_id: session.id,
        request_id: request.id,
        codex_turn_id: turn.id,
        eligible_attempt_id: attempt.id,
        api_key_runtime_epoch: base.api_key.runtime_revocation_epoch,
        model_id: base.model.id,
        model_identifier: base.model.exposed_model_id,
        endpoint: request.endpoint,
        semantic_turn_digest: semantic_digest,
        replay_claim_digest: <<n + 100::256>>,
        owner_instance_id: session.owner_instance_id,
        owner_lease_token: session.owner_lease_token,
        predecessor_epoch: 1,
        failure_reason: :client_disconnected,
        pre_visible_output: true
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    replay_attempt =
      attempt_fixture(request, base.assignment, %{
        attempt_number: 2,
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })
      |> Ecto.Changeset.change(%{model_id: base.model.id, replay_generation: 1})
      |> Repo.update!()

    RequestReplayEntitlement
    |> Repo.get!(armed.entitlement_id)
    |> RequestReplayEntitlement.changeset(%{
      status: "consumed",
      replay_attempt_id: replay_attempt.id,
      provisional_binding_digest: <<n + 200::256>>,
      consumed_at: now,
      started_at: now,
      last_liveness_at: now,
      abandon_at: DateTime.add(now, 60, :second)
    })
    |> Repo.update!()

    %{
      request_id: request.id,
      attempt_id: replay_attempt.id,
      replay_generation: replay_attempt.replay_generation
    }
  end

  defp delete_replay_entitlements!(slug) do
    Repo.delete_all(
      from entitlement in RequestReplayEntitlement,
        join: pool in Pool,
        on: pool.id == entitlement.pool_id,
        where: pool.slug == ^slug
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
