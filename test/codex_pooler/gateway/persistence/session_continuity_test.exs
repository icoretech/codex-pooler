defmodule CodexPooler.Gateway.Persistence.SessionContinuityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, SessionContinuity}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias Ecto.Adapters.SQL.Sandbox

  setup tags do
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings, [])

    if tags[:session_start_race] do
      Application.put_env(
        :codex_pooler,
        OperationalSettings,
        previous_operational_settings
        |> Keyword.delete(:settings)
        |> Keyword.put(:use_instance_settings?, false)
      )
    else
      Application.put_env(
        :codex_pooler,
        OperationalSettings,
        previous_operational_settings
        |> Keyword.delete(:settings)
        |> Keyword.put(:use_instance_settings?, true)
      )

      reset_bootstrap_state_fixture!()
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
      update_gateway_settings(%{"bridge_owner_lease_ttl_seconds" => 45})
    end

    on_exit(fn ->
      Application.put_env(:codex_pooler, OperationalSettings, previous_operational_settings)
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  @tag :session_start_race
  test "concurrent first start for the same session key reuses the winning session" do
    auth =
      Sandbox.unboxed_run(Repo, fn ->
        reset_bootstrap_state_fixture!()
        auth_fixture()
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        reset_bootstrap_state_fixture!()
      end)
    end)

    parent = self()
    barrier = make_ref()
    session_key = "session-start-race-#{System.unique_integer([:positive])}"

    start_task = fn ->
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Process.put({SessionContinuity, :before_session_insert_barrier}, {parent, barrier})

        Sandbox.unboxed_run(Repo, fn ->
          Gateway.start_codex_session(auth, %{
            accepted_turn_state: session_key,
            owner_instance_id: "node-a"
          })
        end)
      end)
    end

    first = start_task.()
    second = start_task.()

    assert_receive {:session_insert_ready, ^barrier, first_pid}, 5_000
    assert_receive {:session_insert_ready, ^barrier, second_pid}, 5_000
    refute first_pid == second_pid

    send(first_pid, {:session_insert_release, barrier})
    send(second_pid, {:session_insert_release, barrier})

    assert [{:ok, %CodexSession{} = first_session}, {:ok, %CodexSession{} = second_session}] =
             [Task.await(first, 10_000), Task.await(second, 10_000)]

    assert first_session.id == second_session.id

    assert 1 ==
             Sandbox.unboxed_run(Repo, fn ->
               active_session_count(auth.pool.id, session_key)
             end)
  end

  @tag :session_start_race
  @tag :session_conflict_recovery
  test "recovered same-caller same-key start reuses the winner through normal continuity" do
    auth = unboxed_auth_fixture!()
    session_key = "session-conflict-same-caller-#{System.unique_integer([:positive])}"

    assert [
             {:ok, %CodexSession{} = first_session},
             {:ok, %CodexSession{} = recovered_session}
           ] =
             contested_start_results(
               [
                 {auth, %{owner_instance_id: "node-a"}},
                 {auth, %{owner_instance_id: "node-b"}}
               ],
               session_key,
               :first_wins
             )

    assert recovered_session.id == first_session.id
    assert unboxed_active_session_count(auth.pool.id, session_key) == 1

    recovered_session = unboxed_get_session!(first_session.id)
    active_lease = unboxed_active_lease!(first_session.id)

    assert recovered_session.status == "active"
    assert active_lease.status == "active"
    assert recovered_session.owner_lease_token == active_lease.lease_token
  end

  @tag :session_start_race
  @tag :session_conflict_recovery
  test "recovered session start conflict logs one sanitized reuse event" do
    auth = unboxed_auth_fixture!()
    raw_session_key = "raw-session-key-#{System.unique_integer([:positive])}"
    api_key_like = "cp_live_sk_test_#{System.unique_integer([:positive])}"
    prompt_text = "synthetic prompt text that must not be logged"
    request_body_like = ~s({"input":"synthetic request body that must not be logged"})

    log =
      capture_info_log(fn ->
        assert [
                 {:ok, %CodexSession{} = first_session},
                 {:ok, %CodexSession{} = recovered_session}
               ] =
                 contested_start_results(
                   [
                     {auth, %{owner_instance_id: "node-a"}},
                     {auth,
                      %{
                        owner_instance_id: "node-b",
                        authorization_header: "Bearer #{api_key_like}",
                        gateway_debug_payload: %{
                          "prompt" => prompt_text,
                          "request_body" => request_body_like
                        }
                      }}
                   ],
                   raw_session_key,
                   :first_wins
                 )

        assert recovered_session.id == first_session.id
      end)

    message =
      "session_start_conflict_recovered reason=codex_sessions_pool_session_key_uq outcome=reused_existing_session"

    assert log =~ message
    assert length(Regex.scan(Regex.compile!(Regex.escape(message)), log)) == 1
    refute log =~ raw_session_key
    refute log =~ api_key_like
    refute log =~ prompt_text
    refute log =~ request_body_like
  end

  @tag :session_start_race
  @tag :session_conflict_recovery
  test "recovered starts preserve normal pool scope and authenticated owner attach api key scope" do
    %{primary_auth: primary_auth, alternate_auth: alternate_auth} = unboxed_same_pool_auths!()
    normal_key = "session-conflict-pool-scope-#{System.unique_integer([:positive])}"

    assert [
             {:ok, %CodexSession{} = primary_session},
             {:ok, %CodexSession{} = alternate_session}
           ] =
             contested_start_results(
               [
                 {primary_auth, %{owner_instance_id: "node-a"}},
                 {alternate_auth, %{owner_instance_id: "node-b"}}
               ],
               normal_key,
               :first_wins
             )

    assert alternate_session.id == primary_session.id
    assert unboxed_active_session_count(primary_auth.pool.id, normal_key) == 1

    owner_attach_key = "session-conflict-owner-attach-#{System.unique_integer([:positive])}"

    assert [
             {:ok, %CodexSession{} = owner_session},
             {:error, %{status: 409, code: "session_start_conflict", param: "session_id"}}
           ] =
             contested_start_results(
               [
                 {primary_auth, %{owner_instance_id: "node-a"}},
                 {alternate_auth,
                  %{owner_instance_id: "node-b", authenticated_owner_attach: true}}
               ],
               owner_attach_key,
               :first_wins
             )

    assert unboxed_get_session!(owner_session.id).api_key_id == primary_auth.api_key.id
    assert unboxed_active_session_count(primary_auth.pool.id, owner_attach_key) == 1

    assert {:error, :owner_unavailable} =
             Sandbox.unboxed_run(Repo, fn ->
               Gateway.start_codex_session(alternate_auth, %{
                 accepted_turn_state: owner_attach_key,
                 authenticated_owner_attach: true
               })
             end)
  end

  @tag :session_start_race
  @tag :session_conflict_recovery
  test "recovered expired-session conflict replaces the expired row instead of resurrecting it" do
    auth = unboxed_auth_fixture!()
    session_key = "session-conflict-expired-#{System.unique_integer([:positive])}"

    expired_session =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %CodexSession{} = session} =
                 Gateway.start_codex_session(auth, %{
                   accepted_turn_state: session_key,
                   owner_instance_id: "node-expired"
                 })

        expire_owner_lease!(session.id)
        Repo.get!(CodexSession, session.id)
      end)

    assert {:ok, %CodexSession{} = replacement} =
             Sandbox.unboxed_run(Repo, fn ->
               Gateway.start_codex_session(auth, %{
                 accepted_turn_state: session_key,
                 owner_instance_id: "node-replacement"
               })
             end)

    refute replacement.id == expired_session.id

    assert %CodexSession{status: "closed"} = unboxed_get_session!(expired_session.id)
    assert %CodexSession{status: "active"} = unboxed_get_session!(replacement.id)
    assert unboxed_active_session_count(auth.pool.id, session_key) == 1
  end

  @tag :session_start_race
  @tag :session_conflict_recovery
  test "recovered sessions keep owner token validation renewal and takeover fencing semantics" do
    auth = unboxed_auth_fixture!()
    session_key = "session-conflict-owner-lease-#{System.unique_integer([:positive])}"

    assert [{:ok, %CodexSession{} = session}, {:ok, %CodexSession{} = recovered_session}] =
             contested_start_results(
               [
                 {auth, %{owner_instance_id: "node-a"}},
                 {auth, %{owner_instance_id: "node-b"}}
               ],
               session_key,
               :first_wins
             )

    assert recovered_session.id == session.id

    Sandbox.unboxed_run(Repo, fn ->
      recovered_session = Repo.get!(CodexSession, session.id)
      initial_lease = active_lease!(session.id)

      assert :ok =
               SessionContinuity.validate_owner_token(
                 session.id,
                 recovered_session.owner_lease_token
               )

      assert {:ok, %CodexSession{} = renewed_session} =
               SessionContinuity.renew_owner_token(
                 session.id,
                 recovered_session.owner_lease_token,
                 owner_request_options(bridge_owner_lease_ttl_seconds: 120)
               )

      renewed_lease = active_lease!(session.id)

      assert renewed_session.id == session.id
      assert renewed_lease.id == initial_lease.id
      assert renewed_lease.lease_token == recovered_session.owner_lease_token
      assert DateTime.diff(renewed_lease.expires_at, renewed_lease.renewed_at, :second) == 120

      stale_snapshot = Repo.get!(CodexSession, session.id)
      takeover_token = Ecto.UUID.generate()
      takeover_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      takeover_expires_at = DateTime.add(takeover_now, 90, :second)

      stale_snapshot
      |> Ecto.Changeset.change(%{
        owner_instance_id: "node-c",
        owner_lease_token: takeover_token,
        owner_lease_expires_at: takeover_expires_at,
        last_heartbeat_at: takeover_now,
        updated_at: takeover_now
      })
      |> Repo.update!()

      renewed_lease
      |> Ecto.Changeset.change(%{
        owner_instance_id: "node-c",
        lease_token: takeover_token,
        renewed_at: takeover_now,
        expires_at: takeover_expires_at,
        updated_at: takeover_now
      })
      |> Repo.update!()

      assert {:error, :stale_owner} =
               SessionContinuity.replace_unavailable_owner_lease(
                 stale_snapshot,
                 owner_request_options(owner_instance_id: "node-d")
               )

      current_session = Repo.get!(CodexSession, session.id)
      current_lease = active_lease!(session.id)

      assert current_session.owner_instance_id == "node-c"
      assert current_session.owner_lease_token == takeover_token
      assert current_lease.id == renewed_lease.id
      assert current_lease.owner_instance_id == "node-c"
      assert current_lease.lease_token == takeover_token
    end)
  end

  test "updated bridge owner lease ttl only affects renewed acquisitions" do
    auth = auth_fixture()

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "lease-ttl-session",
               owner_instance_id: "node-a"
             })

    initial_session = Repo.get!(CodexSession, session.id)
    initial_lease = active_lease!(session.id)

    assert DateTime.diff(
             initial_session.owner_lease_expires_at,
             initial_session.updated_at,
             :second
           ) ==
             45

    assert DateTime.diff(initial_lease.expires_at, initial_lease.renewed_at, :second) == 45

    update_gateway_settings(%{"bridge_owner_lease_ttl_seconds" => 120})

    unchanged_session = Repo.get!(CodexSession, session.id)
    unchanged_lease = Repo.get!(BridgeOwnerLease, initial_lease.id)

    assert unchanged_session.owner_lease_expires_at == initial_session.owner_lease_expires_at
    assert unchanged_lease.expires_at == initial_lease.expires_at

    assert {:ok, %CodexSession{} = renewed_session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state: "lease-ttl-session",
               owner_instance_id: "node-a"
             })

    renewed_session = Repo.get!(CodexSession, renewed_session.id)
    renewed_lease = Repo.get!(BridgeOwnerLease, initial_lease.id)

    assert renewed_session.id == session.id
    assert renewed_lease.id == initial_lease.id

    assert DateTime.diff(
             renewed_session.owner_lease_expires_at,
             renewed_session.updated_at,
             :second
           ) ==
             120

    assert DateTime.diff(renewed_lease.expires_at, renewed_lease.renewed_at, :second) == 120

    assert DateTime.compare(
             renewed_session.owner_lease_expires_at,
             initial_session.owner_lease_expires_at
           ) == :gt

    assert DateTime.compare(renewed_lease.expires_at, initial_lease.expires_at) == :gt
  end

  test "current owner token validates for active unexpired lease" do
    %{session: session, token: token} = owner_session_fixture()

    assert :ok = SessionContinuity.validate_owner_token(session, token)
    assert :ok = SessionContinuity.validate_owner_token(session.id, token)
  end

  test "stale owner token is rejected after token mismatch without mutating persisted state" do
    %{session: session, token: stale_token} = owner_session_fixture()
    active_lease = active_lease!(session.id)
    current_token = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, 90, :second)

    session
    |> Ecto.Changeset.change(%{
      owner_instance_id: "node-b",
      owner_lease_token: current_token,
      owner_lease_expires_at: expires_at,
      last_heartbeat_at: now,
      updated_at: now
    })
    |> Repo.update!()

    active_lease
    |> Ecto.Changeset.change(%{
      owner_instance_id: "node-b",
      lease_token: current_token,
      renewed_at: now,
      expires_at: expires_at,
      updated_at: now
    })
    |> Repo.update!()

    assert {:error, :stale_owner} =
             SessionContinuity.validate_owner_token(session.id, stale_token)

    assert %CodexSession{owner_instance_id: "node-b", owner_lease_token: ^current_token} =
             Repo.get!(CodexSession, session.id)

    assert %BridgeOwnerLease{owner_instance_id: "node-b", lease_token: ^current_token} =
             active_lease!(session.id)
  end

  test "expired lease and missing session reject deterministically" do
    %{session: session, token: token} = owner_session_fixture()
    expire_owner_lease!(session.id)

    assert {:error, :owner_unavailable} =
             SessionContinuity.validate_owner_token(session.id, token)

    assert {:error, :owner_unavailable} =
             SessionContinuity.validate_owner_token(Ecto.UUID.generate(), Ecto.UUID.generate())
  end

  test "current owner token renewal extends expiry without transferring ownership" do
    %{session: session, token: token} =
      owner_session_fixture(%{bridge_owner_lease_ttl_seconds: 30})

    initial_session = Repo.get!(CodexSession, session.id)
    initial_lease = active_lease!(session.id)

    assert {:ok, %CodexSession{} = renewed_session} =
             SessionContinuity.renew_owner_token(
               session.id,
               token,
               owner_request_options(bridge_owner_lease_ttl_seconds: 120)
             )

    renewed_session = Repo.get!(CodexSession, renewed_session.id)
    renewed_lease = active_lease!(session.id)

    assert renewed_session.owner_instance_id == initial_session.owner_instance_id
    assert renewed_session.owner_lease_token == token
    assert renewed_lease.id == initial_lease.id
    assert renewed_lease.owner_instance_id == initial_lease.owner_instance_id
    assert renewed_lease.lease_token == token
    assert renewed_lease.status == "active"

    assert DateTime.compare(
             renewed_session.owner_lease_expires_at,
             initial_session.owner_lease_expires_at
           ) == :gt

    assert DateTime.compare(renewed_lease.expires_at, initial_lease.expires_at) == :gt
    assert DateTime.compare(renewed_lease.renewed_at, initial_lease.renewed_at) in [:gt, :eq]
    assert :ok = SessionContinuity.validate_owner_token(session.id, token)
  end

  test "stale owner token renewal is refused and leaves session and lease unchanged" do
    %{session: session} = owner_session_fixture()
    stale_token = Ecto.UUID.generate()
    before_session = Repo.get!(CodexSession, session.id)
    before_lease = active_lease!(session.id)

    assert {:error, :stale_owner} =
             SessionContinuity.renew_owner_token(
               session.id,
               stale_token,
               owner_request_options(bridge_owner_lease_ttl_seconds: 120)
             )

    after_session = Repo.get!(CodexSession, session.id)
    after_lease = active_lease!(session.id)

    assert after_session.owner_instance_id == before_session.owner_instance_id
    assert after_session.owner_lease_token == before_session.owner_lease_token
    assert after_session.owner_lease_expires_at == before_session.owner_lease_expires_at
    assert after_session.last_heartbeat_at == before_session.last_heartbeat_at
    assert after_lease.lease_token == before_lease.lease_token
    assert after_lease.expires_at == before_lease.expires_at
    assert after_lease.renewed_at == before_lease.renewed_at
  end

  test "active owner renewal keeps a websocket-style turn fenced-valid beyond initial ttl" do
    %{session: session, token: token} =
      owner_session_fixture(%{bridge_owner_lease_ttl_seconds: 1})

    initial_session = Repo.get!(CodexSession, session.id)
    initial_lease = active_lease!(session.id)

    assert {:ok, _renewed_session} =
             SessionContinuity.renew_owner_token(
               session.id,
               token,
               owner_request_options(bridge_owner_lease_ttl_seconds: 120)
             )

    renewed_session = Repo.get!(CodexSession, session.id)
    renewed_lease = active_lease!(session.id)

    assert DateTime.compare(
             renewed_session.owner_lease_expires_at,
             initial_session.owner_lease_expires_at
           ) == :gt

    assert DateTime.compare(renewed_lease.expires_at, initial_lease.expires_at) == :gt
    assert DateTime.diff(renewed_lease.expires_at, renewed_lease.renewed_at, :second) == 120
    assert :ok = SessionContinuity.validate_owner_token(session.id, token)
  end

  test "stopped heartbeat allows token to become unavailable after expiry" do
    %{session: session, token: token} =
      owner_session_fixture(%{bridge_owner_lease_ttl_seconds: 1})

    assert :ok = SessionContinuity.validate_owner_token(session.id, token)

    expire_owner_lease!(session.id)

    assert {:error, :owner_unavailable} =
             SessionContinuity.validate_owner_token(session.id, token)

    assert {:error, :owner_unavailable} =
             SessionContinuity.renew_owner_token(
               session.id,
               token,
               owner_request_options(bridge_owner_lease_ttl_seconds: 120)
             )
  end

  test "owner release is idempotent after lease expiry" do
    %{session: session, token: token} =
      owner_session_fixture(%{bridge_owner_lease_ttl_seconds: 1})

    expire_owner_lease!(session.id)
    lease = active_lease!(session.id)

    assert :ok = SessionContinuity.release_owner_lease(session.id, token, "owner_drained")
    assert :ok = SessionContinuity.release_owner_lease(session.id, token, "owner_drained")

    released_lease = Repo.get!(BridgeOwnerLease, lease.id)

    assert released_lease.status == "released"
    assert released_lease.metadata["release_reason"] == "owner_drained"
    assert %DateTime{} = released_lease.released_at
  end

  test "unavailable owner takeover is refused when owner snapshot changed" do
    %{session: stale_session} = owner_session_fixture()
    before_lease = active_lease!(stale_session.id)
    current_token = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, 90, :second)

    stale_session
    |> Ecto.Changeset.change(%{
      owner_instance_id: "node-b",
      owner_lease_token: current_token,
      owner_lease_expires_at: expires_at,
      last_heartbeat_at: now,
      updated_at: now
    })
    |> Repo.update!()

    before_lease
    |> Ecto.Changeset.change(%{
      owner_instance_id: "node-b",
      lease_token: current_token,
      renewed_at: now,
      expires_at: expires_at,
      updated_at: now
    })
    |> Repo.update!()

    assert {:error, :stale_owner} =
             SessionContinuity.replace_unavailable_owner_lease(
               stale_session,
               owner_request_options(owner_instance_id: "node-c")
             )

    assert %CodexSession{owner_instance_id: "node-b", owner_lease_token: ^current_token} =
             Repo.get!(CodexSession, stale_session.id)

    assert %BridgeOwnerLease{id: active_lease_id, owner_instance_id: "node-b"} =
             active_lease!(stale_session.id)

    assert active_lease_id == before_lease.id
  end

  defp unboxed_auth_fixture! do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      auth_fixture()
    end)
  end

  defp unboxed_same_pool_auths! do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture()
      pool = pool_fixture(%{created_by_user_id: owner.id})
      %{api_key: primary_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
      %{api_key: alternate_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})

      %{
        primary_auth: %{pool: pool, api_key: primary_key},
        alternate_auth: %{pool: pool, api_key: alternate_key}
      }
    end)
  end

  defp contested_start_results(starts, session_key, release_mode) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(starts, fn {auth, opts} ->
        Task.async(fn -> contested_start_result(parent, barrier, auth, session_key, opts) end)
      end)

    ready_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:session_insert_ready, ^barrier, pid}, 5_000
        pid
      end)

    assert Enum.uniq(ready_pids) == ready_pids

    case release_mode do
      :first_wins ->
        [first_task | remaining_tasks] = tasks
        send(first_task.pid, {:session_insert_release, barrier})
        first_result = Task.await(first_task, 10_000)

        Enum.each(remaining_tasks, fn task ->
          send(task.pid, {:session_insert_release, barrier})
        end)

        [first_result | Enum.map(remaining_tasks, &Task.await(&1, 10_000))]

      :together ->
        Enum.each(tasks, fn task ->
          send(task.pid, {:session_insert_release, barrier})
        end)

        Enum.map(tasks, &Task.await(&1, 10_000))
    end
  end

  defp contested_start_result(parent, barrier, auth, session_key, opts) do
    Sandbox.allow(Repo, parent, self())
    Process.put({SessionContinuity, :before_session_insert_barrier}, {parent, barrier})

    Sandbox.unboxed_run(Repo, fn ->
      Gateway.start_codex_session(
        auth,
        Map.merge(%{accepted_turn_state: session_key}, opts)
      )
    end)
  end

  defp unboxed_get_session!(session_id) do
    Sandbox.unboxed_run(Repo, fn -> Repo.get!(CodexSession, session_id) end)
  end

  defp unboxed_active_lease!(session_id) do
    Sandbox.unboxed_run(Repo, fn -> active_lease!(session_id) end)
  end

  defp unboxed_active_session_count(pool_id, session_key) do
    Sandbox.unboxed_run(Repo, fn -> active_session_count(pool_id, session_key) end)
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp owner_session_fixture(opts \\ %{}) do
    auth = auth_fixture()
    suffix = System.unique_integer([:positive])

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(
               auth,
               Map.merge(
                 %{
                   accepted_turn_state: "owner-token-session-#{suffix}",
                   owner_instance_id: "node-a"
                 },
                 opts
               )
             )

    session = Repo.get!(CodexSession, session.id)

    %{auth: auth, session: session, token: session.owner_lease_token}
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        limit: 1
    )
  end

  defp active_session_count(pool_id, session_key) do
    Repo.one!(
      from session in CodexSession,
        where:
          session.pool_id == ^pool_id and
            fragment("lower(?)", session.session_key) == ^String.downcase(session_key) and
            session.status in ["active", "interrupted"],
        select: count(session.id)
    )
  end

  defp expire_owner_lease!(session_id) do
    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.get!(CodexSession, session_id)
    |> Ecto.Changeset.change(%{
      owner_lease_expires_at: expired_at,
      last_heartbeat_at: expired_at,
      updated_at: expired_at
    })
    |> Repo.update!()

    active_lease!(session_id)
    |> Ecto.Changeset.change(%{expires_at: expired_at, updated_at: expired_at})
    |> Repo.update!()
  end

  defp owner_request_options(opts) do
    opts
    |> Map.new()
    |> RequestOptions.for_websocket()
  end

  defp capture_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp update_gateway_settings(attrs) do
    instance_settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update(instance_settings, %{"gateway" => attrs})
  end
end
