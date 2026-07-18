defmodule CodexPooler.Access.APIKeyDashboardSessionLimitsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  describe "public authentication failures" do
    test "missing, malformed, unknown, and opted-out API keys are indistinguishable" do
      %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()

      assert Enum.uniq([
               Access.issue_dashboard_session(nil),
               Access.issue_dashboard_session(""),
               Access.issue_dashboard_session("not-an-api-key"),
               Access.issue_dashboard_session("sk-cxp-000000000000-unknown"),
               Access.issue_dashboard_session(raw_key)
             ]) == [{:error, :invalid_dashboard_credentials}]

      assert api_key.dashboard_access == false
      assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    end

    test "paused, revoked, expired, and inactive-Pool keys are indistinguishable" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      paused = opted_in_key_fixture(status: "paused")
      revoked = opted_in_key_fixture(status: "revoked", revoked_at: now)
      expired = opted_in_key_fixture(expires_at: DateTime.add(now, -1, :second))
      inactive_pool = opted_in_key_fixture()

      inactive_pool.pool
      |> Pool.changeset(%{status: "disabled", disabled_at: now, updated_at: now})
      |> Repo.update!()

      assert Enum.uniq(
               Enum.map([paused, revoked, expired, inactive_pool], fn fixture ->
                 Access.issue_dashboard_session(fixture.raw_key)
               end)
             ) == [{:error, :invalid_dashboard_credentials}]

      assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    end

    test "missing, malformed, and unknown browser tokens are indistinguishable" do
      assert Enum.uniq([
               Access.authenticate_dashboard_session(nil),
               Access.authenticate_dashboard_session(""),
               Access.authenticate_dashboard_session("malformed"),
               Access.authenticate_dashboard_session(
                 :crypto.strong_rand_bytes(32)
                 |> Base.url_encode64(padding: false)
               )
             ]) == [{:error, :invalid_dashboard_session}]
    end
  end

  describe "session operations" do
    test "delete-one revokes only its token and delete-all revokes the remainder" do
      %{api_key: api_key, raw_key: raw_key} = opted_in_key_fixture()

      assert {:ok, %{token: first_token}} = Access.issue_dashboard_session(raw_key)
      assert {:ok, %{token: second_token}} = Access.issue_dashboard_session(raw_key)

      assert :ok = Access.delete_dashboard_session(first_token)

      assert {:error, :invalid_dashboard_session} =
               Access.authenticate_dashboard_session(first_token)

      assert {:ok, _principal} = Access.authenticate_dashboard_session(second_token)

      assert :ok = Access.delete_all_dashboard_sessions(api_key)

      assert {:error, :invalid_dashboard_session} =
               Access.authenticate_dashboard_session(second_token)

      assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    end

    test "authentication never renews the absolute expiry" do
      %{raw_key: raw_key} = opted_in_key_fixture()

      assert {:ok, %{token: token, expires_at: expires_at}} =
               Access.issue_dashboard_session(raw_key)

      session_before = Repo.get_by!(APIKeyDashboardSession, token_hash: hash_token(token))

      assert {:ok, _principal} = Access.authenticate_dashboard_session(token)
      assert {:ok, _principal} = Access.authenticate_dashboard_session(token)

      session_after = Repo.get!(APIKeyDashboardSession, session_before.id)
      assert session_after.expires_at == expires_at
      assert session_after.expires_at == session_before.expires_at
      assert session_after.inserted_at == session_before.inserted_at
    end
  end

  describe "bounded issuance" do
    test "the eleventh active session removes the deterministic oldest row" do
      %{api_key: api_key, raw_key: raw_key} = opted_in_key_fixture()
      tokens = issue_tokens(raw_key, 10)
      oldest_token = hd(tokens)

      Repo.update_all(
        from(session in APIKeyDashboardSession,
          where: session.token_hash == ^hash_token(oldest_token)
        ),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
      )

      assert {:ok, %{token: newest_token}} = Access.issue_dashboard_session(raw_key)

      assert Repo.aggregate(
               from(session in APIKeyDashboardSession,
                 where: session.api_key_id == ^api_key.id
               ),
               :count,
               :id
             ) == 10

      assert {:error, :invalid_dashboard_session} =
               Access.authenticate_dashboard_session(oldest_token)

      assert {:ok, _principal} = Access.authenticate_dashboard_session(newest_token)
    end

    test "issuance purges expiry before applying the active-session cap" do
      %{api_key: api_key, raw_key: raw_key} = opted_in_key_fixture()
      [expiring_token | retained_tokens] = issue_tokens(raw_key, 10)

      Repo.update_all(
        from(session in APIKeyDashboardSession,
          where: session.token_hash == ^hash_token(expiring_token)
        ),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:ok, %{token: replacement_token}} = Access.issue_dashboard_session(raw_key)

      assert Repo.aggregate(
               from(session in APIKeyDashboardSession,
                 where: session.api_key_id == ^api_key.id
               ),
               :count,
               :id
             ) == 10

      assert {:error, :invalid_dashboard_session} =
               Access.authenticate_dashboard_session(expiring_token)

      assert Enum.all?(retained_tokens ++ [replacement_token], fn token ->
               match?({:ok, _principal}, Access.authenticate_dashboard_session(token))
             end)
    end
  end

  defp opted_in_key_fixture(attrs \\ []) do
    attrs = Map.new(attrs)
    fixture = api_key_fixture(pool_fixture(), attrs)

    api_key =
      fixture.api_key
      |> APIKey.changeset(%{dashboard_access: true})
      |> Repo.update!()

    %{fixture | api_key: api_key}
  end

  defp issue_tokens(raw_key, count) do
    Enum.map(1..count, fn _index ->
      assert {:ok, %{token: token}} = Access.issue_dashboard_session(raw_key)
      token
    end)
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)
end
