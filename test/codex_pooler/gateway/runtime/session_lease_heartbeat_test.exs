defmodule CodexPooler.Gateway.Runtime.SessionLeaseHeartbeatTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness
  alias CodexPooler.Gateway.Runtime.SessionLeaseHeartbeat
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Websocket, as: Gateway

  @detection_timeout 15_000
  @handoff_ttl_ms 1_000
  @handoff_early_observation_ms 500
  # The heartbeat has already exited (:DOWN) when this window starts, so it
  # only guards against a renewal write racing the exit; it is not a renewal
  # interval and does not need to span one.
  @handoff_post_stop_observation_ms 100
  @handoff_max_elapsed_ms 5_000
  # The renewal is parked on a barrier that is never released, so this call
  # bound is the only way the synchronous renewal can end.
  @parked_renewal_call_timeout_ms 50

  test "run renews synchronously before a deferred callback and advances both PostgreSQL deadlines" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token, ttl_seconds: 90)
    before_session = Repo.get!(CodexSession, session.id)
    before_lease = active_lease!(session.id)

    assert {:ok, %{stream: stream}} =
             SessionLeaseHeartbeat.run(request_options, fn heartbeat ->
               send(self(), {:heartbeat_ready, heartbeat})
               {:ok, %{stream: fn -> :stream end}}
             end)

    assert is_function(stream, 0)
    assert_receive {:heartbeat_ready, heartbeat}, @detection_timeout

    renewed_session = Repo.get!(CodexSession, session.id)
    renewed_lease = active_lease!(session.id)

    assert DateTime.compare(
             renewed_session.owner_lease_expires_at,
             before_session.owner_lease_expires_at
           ) ==
             :gt

    assert DateTime.compare(renewed_lease.expires_at, before_lease.expires_at) == :gt
    assert renewed_session.owner_lease_expires_at == renewed_lease.expires_at

    assert %{renewal_token: first_token} = :sys.get_state(heartbeat)
    send(heartbeat, {:session_lease_heartbeat_renew, first_token})
    assert_renewed_twice(session.id, renewed_session.owner_lease_expires_at, heartbeat)

    assert :ok = SessionLeaseHeartbeat.stop(heartbeat)
  end

  test "starts only for an attached HTTP owner witness" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)

    assert :ignore =
             SessionLeaseHeartbeat.start(
               RequestOptions.put_transport(request_options, transport: "websocket")
             )

    assert :ignore =
             SessionLeaseHeartbeat.start(
               RequestOptions.put_continuity(request_options, codex_session: nil)
             )

    assert :ignore = SessionLeaseHeartbeat.start(request_options_without_witness(request_options))

    assert :no_heartbeat =
             SessionLeaseHeartbeat.run(
               request_options_without_witness(request_options),
               fn heartbeat ->
                 assert heartbeat == nil
                 :no_heartbeat
               end
             )
  end

  test "the synchronous renewal call keeps its 1 s bound unless a start option overrides it" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)

    assert {:ok, default} = SessionLeaseHeartbeat.start(request_options, schedule?: false)
    assert %{renew_call_timeout_ms: 1_000} = :sys.get_state(default)
    assert :ok = SessionLeaseHeartbeat.stop(default)

    assert {:ok, overridden} =
             SessionLeaseHeartbeat.start(request_options,
               schedule?: false,
               renew_call_timeout_ms: 5_000
             )

    assert %{renew_call_timeout_ms: 5_000} = :sys.get_state(overridden)
    assert :ok = SessionLeaseHeartbeat.stop(overridden)
  end

  test "a synchronous renewal bounds its lock wait below the call and logs one lock timeout" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)
    parent = self()

    Process.put({SessionLeaseHeartbeat, :renew}, fn _session_id,
                                                    _owner_token,
                                                    _renewal_options,
                                                    renewal_opts ->
      send(parent, {:synchronous_renewal_options, renewal_opts})

      {:error,
       {:lock_timeout,
        %{
          relation: :codex_sessions,
          waiter_pid: 4_101,
          blocker: %{
            pid: 4_102,
            state: "idle in transaction",
            wait_event_type: "Client",
            transaction_age_ms: 1_234,
            application_name: "",
            query_fingerprint: "0123456789ab",
            waiting_relation: nil
          }
        }}}
    end)

    logs =
      capture_log(fn ->
        assert {:error, :owner_unavailable} =
                 SessionLeaseHeartbeat.run(request_options, fn ->
                   flunk("callback must not run")
                 end)
      end)

    assert_received {:synchronous_renewal_options, [lock_timeout_ms: 800]}

    assert [line] = renewal_failure_lines(logs)
    assert line =~ "phase=synchronous reason=lock_timeout"
    assert line =~ "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(session.id)}"

    assert line =~
             "relation=codex_sessions waiter_pid=4101 blocker=resolved blocker_pid=4102 " <>
               "blocker_state=idle_in_transaction " <>
               "blocker_wait_event_type=Client blocker_xact_age_ms=1234 " <>
               "blocker_application=none blocker_query_fingerprint=0123456789ab " <>
               "blocker_waiting_relation=none"

    refute logs =~ token
  end

  test "a synchronous renewal that outlives its call bound is killed and logged once" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token, observer: self())

    Process.put({SessionLeaseHeartbeat, :renew_call_timeout_ms}, @parked_renewal_call_timeout_ms)

    Process.put({SessionLeaseHeartbeat, :renew}, fn _session_id,
                                                    _owner_token,
                                                    _renewal_options,
                                                    _renewal_opts ->
      receive do
        :release_parked_renewal -> {:ok, session}
      end
    end)

    logs =
      capture_log(fn ->
        assert {:error, :owner_unavailable} =
                 SessionLeaseHeartbeat.run(request_options, fn ->
                   flunk("callback must not run")
                 end)
      end)

    assert_received {:session_lease_heartbeat, :started, heartbeat}
    refute Process.alive?(heartbeat)

    assert [line] = renewal_failure_lines(logs)
    assert line =~ "phase=synchronous reason=call_timeout"
    refute logs =~ token
  end

  test "a failed scheduled renewal stops the heartbeat with one unbounded-wait warning" do
    for {failure, reason_class} <- [
          {fn -> {:error, :stale_owner} end, "stale_owner"},
          {fn -> raise DBConnection.ConnectionError, "synthetic" end, "database_unavailable"}
        ] do
      %{session: session, token: token} = owner_session_fixture()
      request_options = http_request_options(session, token)
      parent = self()

      renew = fn _session_id, _owner_token, _renewal_options, renewal_opts ->
        send(parent, {:scheduled_renewal_options, renewal_opts})
        failure.()
      end

      logs =
        capture_log(fn ->
          assert {:ok, heartbeat} = SessionLeaseHeartbeat.start(request_options, renew: renew)
          assert %{renewal_token: renewal_token} = :sys.get_state(heartbeat)
          monitor = Process.monitor(heartbeat)

          send(heartbeat, {:session_lease_heartbeat_renew, renewal_token})

          assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, @detection_timeout
        end)

      assert_received {:scheduled_renewal_options, []}

      assert [line] = renewal_failure_lines(logs)
      assert line =~ "phase=scheduled reason=#{reason_class}"
      assert line =~ "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(session.id)}"
      refute logs =~ token
    end
  end

  test "uses the bounded cadence and reschedules only after a successful renewal" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token, ttl_seconds: 9)
    parent = self()
    delay_ref = make_ref()

    renew = fn session_id, owner_token, renewal_options ->
      send(
        parent,
        {:renewed, session_id, owner_token,
         renewal_options.continuity.bridge_owner_lease_ttl_seconds}
      )

      {:ok, session}
    end

    delay = fn interval ->
      send(parent, {:scheduled, delay_ref, interval})
      interval
    end

    assert {:ok, heartbeat} =
             SessionLeaseHeartbeat.start(request_options,
               renew: renew,
               renewal_interval_ms: 60_000,
               renewal_delay: delay
             )

    assert_receive {:scheduled, ^delay_ref, 3_000}, @detection_timeout
    assert %{renewal_token: renewal_token, renewal_ref: renewal_ref} = :sys.get_state(heartbeat)
    assert is_reference(renewal_ref)

    send(heartbeat, {:session_lease_heartbeat_renew, renewal_token})

    session_id = session.id
    assert_receive {:renewed, ^session_id, ^token, 9}, @detection_timeout
    assert_receive {:scheduled, ^delay_ref, 3_000}, @detection_timeout

    assert :ok = SessionLeaseHeartbeat.stop(heartbeat)
  end

  test "stops without rescheduling after stale or unavailable ownership" do
    for reason <- [:stale_owner, :owner_unavailable] do
      %{session: session, token: token} = owner_session_fixture()
      request_options = http_request_options(session, token)
      parent = self()

      renew = fn _session_id, _owner_token, _renewal_options ->
        send(parent, {:renewal_attempt, reason})
        {:error, reason}
      end

      assert {:ok, heartbeat} = SessionLeaseHeartbeat.start(request_options, renew: renew)
      assert %{renewal_token: renewal_token} = :sys.get_state(heartbeat)
      monitor = Process.monitor(heartbeat)

      send(heartbeat, {:session_lease_heartbeat_renew, renewal_token})

      assert_receive {:renewal_attempt, ^reason}, @detection_timeout
      assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, @detection_timeout
      refute_received {:renewal_attempt, ^reason}
    end
  end

  test "stops without logging the lease token after an unexpected renewal failure" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)

    renew = fn _session_id, _owner_token, _renewal_options ->
      raise "database failure"
    end

    logs =
      capture_log(fn ->
        assert {:ok, heartbeat} = SessionLeaseHeartbeat.start(request_options, renew: renew)
        assert %{renewal_token: renewal_token} = :sys.get_state(heartbeat)
        monitor = Process.monitor(heartbeat)

        send(heartbeat, {:session_lease_heartbeat_renew, renewal_token})

        assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, @detection_timeout
      end)

    refute logs =~ token
  end

  test "caller death and explicit stop terminate the heartbeat idempotently" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)

    caller =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, heartbeat} = SessionLeaseHeartbeat.start(request_options, caller: caller)
    monitor = Process.monitor(heartbeat)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, @detection_timeout
    assert :ok = SessionLeaseHeartbeat.stop(heartbeat)
    assert :ok = SessionLeaseHeartbeat.stop(heartbeat)
  end

  test "an abandoned deferred handoff stops after one owner ttl while its caller remains alive" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token, ttl_seconds: 1)
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{stream: _stream}} =
             SessionLeaseHeartbeat.run(request_options, fn heartbeat ->
               send(self(), {:handoff_heartbeat, heartbeat})
               {:ok, %{stream: fn -> :stream end}}
             end)

    assert_receive {:handoff_heartbeat, heartbeat}, @detection_timeout
    monitor = Process.monitor(heartbeat)
    Process.send_after(self(), :handoff_early_observation, @handoff_early_observation_ms)

    assert_receive :handoff_early_observation, @detection_timeout
    assert Process.alive?(heartbeat)
    refute_received {:DOWN, ^monitor, :process, ^heartbeat, _reason}

    assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, @detection_timeout
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= @handoff_ttl_ms
    assert elapsed_ms <= @handoff_max_elapsed_ms

    assert Process.alive?(self())

    session_after_stop = Repo.get!(CodexSession, session.id)
    lease_after_stop = active_lease!(session.id)

    Process.send_after(
      self(),
      :handoff_post_stop_observation,
      @handoff_post_stop_observation_ms
    )

    assert_receive :handoff_post_stop_observation, @detection_timeout

    session_after_observation = Repo.get!(CodexSession, session.id)
    lease_after_observation = active_lease!(session.id)

    assert session_after_observation.last_heartbeat_at == session_after_stop.last_heartbeat_at

    assert session_after_observation.owner_lease_expires_at ==
             session_after_stop.owner_lease_expires_at

    assert lease_after_observation.renewed_at == lease_after_stop.renewed_at
    assert lease_after_observation.expires_at == lease_after_stop.expires_at
  end

  test "stream start clears the abandoned-handoff deadline" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)

    assert {:ok, %{stream: _stream}} =
             SessionLeaseHeartbeat.run(request_options, fn heartbeat ->
               send(self(), {:stream_heartbeat, heartbeat})
               {:ok, %{stream: fn -> :stream end}}
             end)

    assert_receive {:stream_heartbeat, heartbeat}, @detection_timeout
    assert :ok = SessionLeaseHeartbeat.stream_started(heartbeat)
    assert %{handoff_token: nil, handoff_ref: nil} = :sys.get_state(heartbeat)
    assert :ok = SessionLeaseHeartbeat.stop(heartbeat)
  end

  test "preserves a deferred callback result when the heartbeat stops before handoff" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)
    parent = self()
    continue_ref = make_ref()

    task =
      Task.async(fn ->
        SessionLeaseHeartbeat.run(request_options, fn heartbeat ->
          send(parent, {:deferred_callback_ready, heartbeat, self()})

          receive do
            {:return_deferred_result, ^continue_ref} ->
              {:ok, %{stream: fn -> :delivered end}}
          after
            @detection_timeout -> raise "deferred callback was not released"
          end
        end)
      end)

    assert_receive {:deferred_callback_ready, heartbeat, callback_pid}, @detection_timeout
    heartbeat_ref = Process.monitor(heartbeat)
    Process.exit(heartbeat, :kill)
    assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat, :killed}, @detection_timeout
    send(callback_pid, {:return_deferred_result, continue_ref})

    assert {:ok, %{stream: stream}} = Task.await(task, @detection_timeout)
    assert stream.() == :delivered
  end

  test "run maps stale and unavailable synchronous renewal failures without invoking the callback" do
    %{session: session, token: token} = owner_session_fixture()
    request_options = http_request_options(session, token)

    expire_owner_lease!(session.id)

    assert {:ok, replacement} =
             SessionContinuity.replace_unavailable_owner_lease(
               session,
               RequestOptions.for_websocket(owner_instance_id: "replacement-owner")
             )

    assert replacement.owner_lease_token != token

    assert {:error, :stale_owner} =
             SessionLeaseHeartbeat.run(request_options, fn -> flunk("callback must not run") end)

    expire_owner_lease!(session.id)

    assert {:error, :owner_unavailable} =
             SessionLeaseHeartbeat.run(request_options, fn -> flunk("callback must not run") end)
  end

  defp assert_renewed_twice(session_id, previous_expiry, heartbeat) do
    assert %{renewal_token: second_token} = :sys.get_state(heartbeat)
    send(heartbeat, {:session_lease_heartbeat_renew, second_token})
    _state_after_second_renewal = :sys.get_state(heartbeat)
    session = Repo.get!(CodexSession, session_id)
    lease = active_lease!(session_id)

    assert session.owner_lease_expires_at == lease.expires_at
    assert DateTime.compare(session.owner_lease_expires_at, previous_expiry) == :gt
  end

  defp renewal_failure_lines(logs) do
    logs
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "session lease renewal failed"))
  end

  defp http_request_options(%CodexSession{} = session, token, opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 45)

    observer_options =
      case Keyword.get(opts, :observer) do
        observer when is_pid(observer) -> [session_lease_heartbeat_test_observer: observer]
        nil -> []
      end

    request_options =
      RequestOptions.build(
        [
          codex_session: session,
          bridge_owner_lease_ttl_seconds: ttl_seconds,
          transport: "http_json"
        ] ++ observer_options,
        "/backend-api/codex/responses",
        %{}
      )

    {:ok, witness} = OwnerWitness.new(%{session | owner_lease_token: token})
    RequestOptions.put_session_owner_witness(request_options, witness)
  end

  defp request_options_without_witness(request_options) do
    %{request_options | runtime: %{request_options.runtime | session_owner_witness: nil}}
  end

  defp owner_session_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(%{pool: pool, api_key: api_key}, %{
               accepted_turn_state: "heartbeat-#{System.unique_integer([:positive])}",
               owner_instance_id: "heartbeat-owner"
             })

    session = Repo.get!(CodexSession, session.id)
    %{session: session, token: session.owner_lease_token}
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        limit: 1
    )
  end

  defp expire_owner_lease!(session_id) do
    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.get!(CodexSession, session_id)
    |> Ecto.Changeset.change(%{owner_lease_expires_at: expired_at, updated_at: expired_at})
    |> Repo.update!()

    active_lease!(session_id)
    |> Ecto.Changeset.change(%{expires_at: expired_at, updated_at: expired_at})
    |> Repo.update!()
  end
end
