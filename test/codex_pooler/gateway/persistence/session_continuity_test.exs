defmodule CodexPooler.Gateway.Persistence.SessionContinuityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, SessionContinuity}
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  setup do
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings, [])

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

    on_exit(fn ->
      Application.put_env(:codex_pooler, OperationalSettings, previous_operational_settings)
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
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

  defp update_gateway_settings(attrs) do
    instance_settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update(instance_settings, %{"gateway" => attrs})
  end
end
