defmodule CodexPooler.Upstreams.OAuthFlowTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.FakeOpenAIAuthProvider
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.OAuthFlows
  alias CodexPooler.Upstreams.Schemas.OAuthFlow
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  describe "schema validations" do
    test "requires ownership, kind, purpose, status, expiry, and metadata fields" do
      changeset = OAuthFlow.changeset(struct(OAuthFlow), %{})

      assert errors_on(changeset) == %{
               expires_at: ["can't be blank"],
               flow_kind: ["can't be blank"],
               metadata: ["can't be blank"],
               pool_id: ["can't be blank"],
               purpose: ["can't be blank"],
               requested_by_user_id: ["can't be blank"],
               status: ["can't be blank"]
             }
    end

    test "rejects malformed enum values" do
      attrs =
        base_attrs()
        |> Map.merge(%{
          flow_kind: "script",
          purpose: "rotate",
          status: "waiting"
        })

      changeset = OAuthFlow.changeset(struct(OAuthFlow), attrs)

      assert "is invalid" in errors_on(changeset).flow_kind
      assert "is invalid" in errors_on(changeset).purpose
      assert "is invalid" in errors_on(changeset).status
    end

    test "normalizes and hashes raw state tokens without storing raw state" do
      raw_state = "state-token-do-not-store"

      assert {:ok, flow} =
               base_attrs()
               |> Map.put(:state_token, "  #{raw_state}  ")
               |> OAuthFlows.create_oauth_flow()

      assert is_binary(flow.state_token_hash)
      assert byte_size(flow.state_token_hash) == 32
      assert flow.state_token_hash == OAuthFlows.hash_state_token(raw_state)
      refute inspect(flow) =~ raw_state
    end

    test "ignores direct storage-column state hash input so raw state cannot bypass hashing" do
      raw_state = "state-token-do-not-store"
      bypass_value = String.duplicate("x", 32)

      assert {:ok, flow} =
               base_attrs()
               |> Map.put(:state_token, raw_state)
               |> Map.put(:state_token_hash, bypass_value)
               |> OAuthFlows.create_oauth_flow()

      assert flow.state_token_hash == OAuthFlows.hash_state_token(raw_state)
      refute flow.state_token_hash == bypass_value
    end

    test "unique partial state hash prevents duplicate browser flows with the same state" do
      raw_state = "duplicate-state-token"

      assert {:ok, _flow} =
               base_attrs()
               |> Map.put(:state_token, raw_state)
               |> OAuthFlows.create_oauth_flow()

      assert {:error, changeset} =
               base_attrs()
               |> Map.put(:state_token, raw_state)
               |> OAuthFlows.create_oauth_flow()

      assert %{state_token_hash: ["has already been taken"]} = errors_on(changeset)
    end

    test "malformed required enum values are rejected by database constraints too" do
      attrs = base_attrs()
      now = DateTime.utc_now()

      assert_raise Postgrex.Error, ~r/upstream_oauth_flows_flow_kind_check/, fn ->
        Repo.query!(
          """
          INSERT INTO upstream_oauth_flows (
            id, pool_id, requested_by_user_id, flow_kind, purpose, status, expires_at,
            metadata, inserted_at, updated_at
          )
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'script', 'link', 'pending', $4, '{}', $5, $5)
          """,
          [
            Ecto.UUID.bingenerate(),
            Ecto.UUID.dump!(attrs.pool_id),
            Ecto.UUID.dump!(attrs.requested_by_user_id),
            attrs.expires_at,
            now
          ]
        )
      end
    end
  end

  describe "transient secret storage" do
    setup do
      configure_upstream_secret_key!()
      :ok
    end

    test "encrypts and decrypts PKCE verifier without plaintext persistence" do
      plaintext = "pkce-verifier-do-not-store"

      assert {:ok, flow} =
               base_attrs()
               |> Map.merge(%{
                 flow_kind: "browser",
                 redirect_uri: "http://localhost:1455/auth/callback",
                 code_verifier: plaintext
               })
               |> OAuthFlows.create_oauth_flow()

      assert is_binary(flow.code_verifier_ciphertext)
      refute flow.code_verifier_ciphertext =~ plaintext
      refute inspect(flow) =~ plaintext

      assert {:ok,
              %{
                "v" => 1,
                "ciphertext" => ciphertext,
                "nonce" => nonce,
                "aad" => %{"domain" => "upstream_oauth_flow"}
              }} = CodexPooler.JSON.decode(flow.code_verifier_ciphertext)

      assert is_binary(ciphertext)
      assert is_binary(nonce)

      assert {:ok, ^plaintext} = OAuthFlows.decrypt_code_verifier(flow)

      persisted = Repo.get!(OAuthFlow, flow.id)
      refute inspect(persisted.metadata) =~ plaintext
      assert {:ok, ^plaintext} = OAuthFlows.decrypt_code_verifier(persisted)

      assert {:error, %{code: :upstream_secret_invalid_ciphertext}} =
               OAuthFlows.decrypt_code_verifier(%{
                 flow
                 | code_verifier_ciphertext: ~s({"v":1,"ciphertext":false,"nonce":false,"aad":{}})
               })
    end

    test "ignores direct verifier ciphertext input so plaintext cannot bypass encryption" do
      plaintext = "pkce-verifier-do-not-store"
      bypass_value = String.duplicate("v", 32)

      assert {:ok, flow} =
               base_attrs()
               |> Map.merge(%{
                 flow_kind: "browser",
                 code_verifier: plaintext,
                 code_verifier_ciphertext: bypass_value
               })
               |> OAuthFlows.create_oauth_flow()

      assert is_binary(flow.code_verifier_ciphertext)
      refute flow.code_verifier_ciphertext == bypass_value
      assert {:ok, ^plaintext} = OAuthFlows.decrypt_code_verifier(flow)
    end

    test "encrypts and decrypts device auth id without putting it in metadata" do
      plaintext = "device-auth-id-do-not-store"

      assert {:ok, flow} =
               base_attrs()
               |> Map.merge(%{
                 flow_kind: "device",
                 device_auth_id: plaintext,
                 device_user_code: "ABCD-EFGH",
                 verification_uri: "https://auth.openai.com/codex/device",
                 interval_seconds: 5
               })
               |> OAuthFlows.create_oauth_flow()

      assert is_binary(flow.device_auth_id_ciphertext)
      refute flow.device_auth_id_ciphertext =~ plaintext
      refute inspect(flow) =~ plaintext
      assert {:ok, ^plaintext} = OAuthFlows.decrypt_device_auth_id(flow)

      persisted = Repo.get!(OAuthFlow, flow.id)
      refute inspect(persisted.metadata) =~ plaintext
      assert {:ok, ^plaintext} = OAuthFlows.decrypt_device_auth_id(persisted)
    end

    test "ignores direct device auth ciphertext input so plaintext cannot bypass encryption" do
      plaintext = "device-auth-id-do-not-store"
      bypass_value = String.duplicate("d", 32)

      assert {:ok, flow} =
               base_attrs()
               |> Map.merge(%{
                 flow_kind: "device",
                 device_auth_id: plaintext,
                 device_auth_id_ciphertext: bypass_value
               })
               |> OAuthFlows.create_oauth_flow()

      assert is_binary(flow.device_auth_id_ciphertext)
      refute flow.device_auth_id_ciphertext == bypass_value
      assert {:ok, ^plaintext} = OAuthFlows.decrypt_device_auth_id(flow)
    end
  end

  describe "expiry and cleanup" do
    test "expires pending flows whose expiry is at or before now" do
      now = ~U[2026-06-10 20:00:00.000000Z]

      assert {:ok, expired} =
               base_attrs(%{expires_at: DateTime.add(now, -1, :second)})
               |> OAuthFlows.create_oauth_flow()

      assert {:ok, active} =
               base_attrs(%{expires_at: DateTime.add(now, 60, :second)})
               |> OAuthFlows.create_oauth_flow()

      assert %{expired: 1, deleted: 0} = OAuthFlows.cleanup_oauth_flows(now)

      assert Repo.get!(OAuthFlow, expired.id).status == "expired"
      assert Repo.get!(OAuthFlow, active.id).status == "pending"
    end

    test "deletes terminal flows older than seven days" do
      now = ~U[2026-06-10 20:00:00.000000Z]
      old_terminal_time = DateTime.add(now, -8, :day)
      recent_terminal_time = DateTime.add(now, -6, :day)

      assert {:ok, old_terminal} =
               base_attrs(%{
                 status: "failed",
                 expires_at: DateTime.add(now, -9, :day),
                 updated_at: old_terminal_time
               })
               |> OAuthFlows.create_oauth_flow()

      assert {:ok, recent_terminal} =
               base_attrs(%{
                 status: "cancelled",
                 expires_at: DateTime.add(now, -8, :day),
                 updated_at: recent_terminal_time
               })
               |> OAuthFlows.create_oauth_flow()

      assert %{expired: 0, deleted: 1} = OAuthFlows.cleanup_oauth_flows(now)

      refute Repo.get(OAuthFlow, old_terminal.id)
      assert Repo.get!(OAuthFlow, recent_terminal.id).status == "cancelled"
    end
  end

  describe "flow lifecycle APIs" do
    setup do
      configure_upstream_secret_key!()
      restore_codex_auth_config!()
      :ok
    end

    test "start_browser_oauth requires pool operate capability before writing a flow" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
      admin_scope = Scope.for_user(admin)
      pool = pool_fixture()

      assert {:error,
              %{
                code: :unauthorized_pool,
                message: "Pool authorization is required for this OAuth flow"
              }} =
               Upstreams.start_browser_oauth(admin_scope, pool)

      assert Repo.aggregate(OAuthFlow, :count) == 0
    end

    test "start_browser_oauth creates a pending browser flow with hashed state and encrypted verifier" do
      scope = fixture_owner_scope()
      pool = pool_fixture()

      assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
               Upstreams.start_browser_oauth(scope, pool)

      parsed = URI.parse(authorization_url)
      query = URI.decode_query(parsed.query)

      assert query["state"]
      assert query["code_challenge"]
      assert query["redirect_uri"] == CodexAuth.browser_redirect_uri()
      assert flow.pool_id == pool.id
      assert flow.requested_by_user_id == scope.user.id
      assert flow.flow_kind == "browser"
      assert flow.purpose == "link"
      assert flow.status == "pending"
      assert flow.redirect_uri == CodexAuth.browser_redirect_uri()
      assert flow.state_token_hash == OAuthFlows.hash_state_token(query["state"])
      assert {:ok, verifier} = OAuthFlows.decrypt_code_verifier(flow)
      assert CodexAuth.pkce_challenge(verifier) == query["code_challenge"]
      refute inspect(flow) =~ query["state"]
      refute inspect(flow) =~ verifier
    end

    test "start_browser_oauth drops sensitive caller-supplied metadata keys" do
      scope = fixture_owner_scope()
      pool = pool_fixture()

      assert {:ok, %{flow: flow}} =
               Upstreams.start_browser_oauth(scope, pool,
                 metadata: %{
                   "source" => "admin-upstreams",
                   "callback_url" =>
                     "http://localhost:1455/auth/callback?state=drop-state&code=drop-code",
                   "state" => "drop-state",
                   "code_verifier" => "drop-verifier",
                   "device_auth_id" => "drop-device-auth",
                   "provider_payload" => ~s({"access_token":"drop-access-token"}),
                   token: "drop-token"
                 }
               )

      assert flow.metadata == %{
               "requested_by_user_id" => scope.user.id,
               "source" => "admin-upstreams"
             }

      refute inspect(flow.metadata) =~ "drop-state"
      refute inspect(flow.metadata) =~ "drop-verifier"
      refute inspect(flow.metadata) =~ "drop-device-auth"
      refute inspect(flow.metadata) =~ "drop-access-token"
    end

    test "start_device_oauth creates a pending device flow from provider device-code response" do
      scope = fixture_owner_scope()
      pool = pool_fixture()
      expires_at = DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.to_iso8601()

      provider =
        start_provider!(%{
          "/api/accounts/deviceauth/usercode" =>
            {200,
             FakeOpenAIAuthProvider.device_code_response(
               device_auth_id: "device-auth-lifecycle",
               user_code: "CODE-LIFE",
               expires_at: expires_at,
               interval: 9
             )}
        })

      assert {:ok, %{flow: flow}} = Upstreams.start_device_oauth(scope, pool)

      assert flow.pool_id == pool.id
      assert flow.requested_by_user_id == scope.user.id
      assert flow.flow_kind == "device"
      assert flow.purpose == "link"
      assert flow.status == "pending"
      assert flow.device_user_code == "CODE-LIFE"
      assert flow.verification_uri == FakeOpenAIAuthProvider.url(provider) <> "/codex/device"
      assert flow.interval_seconds == 9
      assert flow.poll_after_at
      assert {:ok, "device-auth-lifecycle"} = OAuthFlows.decrypt_device_auth_id(flow)
    end

    test "concurrent browser starts leave one pending flow and cancel superseded pending flows" do
      scope = fixture_owner_scope()
      pool = pool_fixture()
      parent = self()

      tasks =
        for _index <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            Upstreams.start_browser_oauth(scope, pool)
          end)
        end

      assert [{:ok, _first}, {:ok, _second}] = Enum.map(tasks, &Task.await(&1, 2_000))

      flows =
        Repo.all(
          from(flow in OAuthFlow,
            where: flow.pool_id == ^pool.id,
            order_by: [asc: flow.inserted_at]
          )
        )

      assert Enum.count(flows, &(&1.status == "pending")) == 1
      assert Enum.count(flows, &(&1.status == "cancelled")) == 1

      assert [%OAuthFlow{error_code: "stale_flow", cancelled_at: %DateTime{}}] =
               Enum.filter(flows, &(&1.status == "cancelled"))
    end

    test "browser starts supersede only the same non-nil identity and purpose" do
      scope = fixture_owner_scope()
      pool = pool_fixture()
      first_identity = active_upstream_identity_fixture()
      second_identity = active_upstream_identity_fixture()

      assert {:ok, %{flow: unassigned_flow}} =
               Upstreams.start_browser_oauth(scope, pool, purpose: "relink")

      assert {:ok, %{flow: first_identity_old}} =
               Upstreams.start_browser_oauth(scope, pool, upstream_identity: first_identity)

      assert {:ok, %{flow: first_identity_new}} =
               Upstreams.start_browser_oauth(scope, pool, upstream_identity: first_identity)

      assert {:ok, %{flow: second_identity_flow}} =
               Upstreams.start_browser_oauth(scope, pool, upstream_identity: second_identity)

      flows =
        Repo.all(
          from(flow in OAuthFlow,
            where:
              flow.id in ^[
                unassigned_flow.id,
                first_identity_old.id,
                first_identity_new.id,
                second_identity_flow.id
              ]
          )
        )
        |> Map.new(&{&1.id, &1})

      assert flows[unassigned_flow.id].status == "pending"
      assert flows[unassigned_flow.id].upstream_identity_id == nil

      assert flows[first_identity_old.id].status == "cancelled"
      assert flows[first_identity_old.id].error_code == "stale_flow"
      assert flows[first_identity_new.id].status == "pending"
      assert flows[first_identity_new.id].upstream_identity_id == first_identity.id

      assert flows[second_identity_flow.id].status == "pending"
      assert flows[second_identity_flow.id].upstream_identity_id == second_identity.id
    end

    test "cancel_oauth_flow marks pending flows terminal and is idempotent" do
      scope = fixture_owner_scope()
      pool = pool_fixture()

      assert {:ok, %{flow: flow}} = Upstreams.start_browser_oauth(scope, pool)

      assert {:ok, cancelled} = Upstreams.cancel_oauth_flow(scope, flow.id)
      assert cancelled.status == "cancelled"
      assert cancelled.error_code == "stale_flow"
      assert %DateTime{} = cancelled.cancelled_at

      assert {:ok, same_cancelled} = Upstreams.cancel_oauth_flow(scope, flow.id)
      assert same_cancelled.id == flow.id
      assert same_cancelled.status == "cancelled"
      assert Repo.aggregate(OAuthFlow, :count) == 1
    end

    test "cancel_oauth_flow enforces flow pool authorization" do
      owner_scope = fixture_owner_scope()
      pool = pool_fixture()
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
      admin_scope = Scope.for_user(admin)

      assert {:ok, %{flow: flow}} = Upstreams.start_browser_oauth(owner_scope, pool)

      assert {:error, %{code: :unauthorized_pool}} =
               Upstreams.cancel_oauth_flow(admin_scope, flow.id)

      assert Repo.get!(OAuthFlow, flow.id).status == "pending"
    end

    test "complete_browser_oauth enforces pool authorization before parsing provider denial" do
      owner_scope = fixture_owner_scope()
      admin_scope = fixture_unassigned_admin_scope()
      pool = pool_fixture()

      assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
               Upstreams.start_browser_oauth(owner_scope, pool)

      state = authorization_state(authorization_url)

      denied_callback_url =
        "http://localhost:1455/auth/callback?" <>
          URI.encode_query(%{"state" => state, "error" => "access_denied"})

      assert {:error, %{code: :unauthorized_pool}} =
               Upstreams.complete_browser_oauth(admin_scope, flow.id, denied_callback_url)

      assert Repo.get!(OAuthFlow, flow.id).status == "pending"
    end

    test "poll_device_oauth enforces flow pool authorization" do
      owner_scope = fixture_owner_scope()
      admin_scope = fixture_unassigned_admin_scope()
      pool = pool_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, flow} =
               base_attrs(%{
                 pool: pool,
                 user: owner_scope.user,
                 flow_kind: "device",
                 device_auth_id: "poll-authz-device",
                 interval_seconds: 5,
                 poll_after_at: DateTime.add(now, 5, :second)
               })
               |> OAuthFlows.create_oauth_flow()

      assert {:error, %{code: :unauthorized_pool}} =
               Upstreams.poll_device_oauth(admin_scope, flow.id)

      reloaded = Repo.get!(OAuthFlow, flow.id)
      assert reloaded.status == "pending"
      assert reloaded.last_polled_at == nil
    end

    test "expire_oauth_flows expires pending rows and complete_browser_oauth rejects expired flows" do
      scope = fixture_owner_scope()
      pool = pool_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, flow} =
               base_attrs(%{
                 pool: pool,
                 user: scope.user,
                 expires_at: DateTime.add(now, -1, :second)
               })
               |> Map.put(:state_token, "expired-flow-state")
               |> OAuthFlows.create_oauth_flow()

      assert %{expired: 1, deleted: 0} = Upstreams.expire_oauth_flows(now)

      assert {:error, %{code: :expired_flow}} =
               Upstreams.complete_browser_oauth(
                 scope,
                 flow.id,
                 "http://localhost:1455/auth/callback?state=expired-flow-state&code=code_123"
               )
    end

    test "complete_browser_oauth locks the flow and returns idempotent completed success" do
      scope = fixture_owner_scope()
      pool = pool_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, completed} =
               base_attrs(%{
                 pool: pool,
                 user: scope.user,
                 status: "completed",
                 completed_at: now,
                 metadata: %{"completion_marker" => "already_done"}
               })
               |> Map.put(:state_token, "completed-flow-state")
               |> OAuthFlows.create_oauth_flow()

      assert {:ok, %{status: :completed, flow: returned}} =
               Upstreams.complete_browser_oauth(
                 scope,
                 completed.id,
                 "http://localhost:1455/auth/callback?state=completed-flow-state&code=code_123"
               )

      assert returned.id == completed.id
      assert returned.status == "completed"
      assert Repo.aggregate(OAuthFlow, :count) == 1
    end

    test "complete_browser_oauth rejects cancelled failed superseded or wrong-state flows safely" do
      scope = fixture_owner_scope()
      pool = pool_fixture()

      for {status, code} <- [{"cancelled", :stale_flow}, {"failed", :flow_not_pending}] do
        assert {:ok, flow} =
                 base_attrs(%{
                   pool: pool,
                   user: scope.user,
                   status: status,
                   error_code: to_string(code)
                 })
                 |> Map.put(:state_token, "state-#{status}")
                 |> OAuthFlows.create_oauth_flow()

        assert {:error, %{code: ^code}} =
                 Upstreams.complete_browser_oauth(
                   scope,
                   flow.id,
                   "http://localhost:1455/auth/callback?state=state-#{status}&code=code_123"
                 )
      end

      assert {:ok, %{flow: pending}} = Upstreams.start_browser_oauth(scope, pool)

      assert {:error, %{code: :invalid_state}} =
               Upstreams.complete_browser_oauth(
                 scope,
                 pending.id,
                 "http://localhost:1455/auth/callback?state=wrong-state&code=code_123"
               )

      assert Repo.get!(OAuthFlow, pending.id).status == "pending"
    end

    test "cleanup deletes terminal rows after retention through public facade" do
      now = ~U[2026-06-10 20:00:00.000000Z]

      assert {:ok, _old_terminal} =
               base_attrs(%{
                 status: "failed",
                 expires_at: DateTime.add(now, -9, :day),
                 updated_at: DateTime.add(now, -8, :day)
               })
               |> OAuthFlows.create_oauth_flow()

      assert %{expired: 0, deleted: 1} = Upstreams.cleanup_oauth_flows(now)
      assert Repo.aggregate(OAuthFlow, :count) == 0
    end
  end

  defp base_attrs(overrides \\ %{}) do
    pool = Map.get(overrides, :pool) || pool_fixture()
    user = Map.get(overrides, :user) || user_fixture()
    identity = Map.get(overrides, :identity)

    %{
      pool_id: pool.id,
      upstream_identity_id: identity && identity.id,
      requested_by_user_id: user.id,
      flow_kind: Map.get(overrides, :flow_kind, "browser"),
      purpose: Map.get(overrides, :purpose, "link"),
      status: Map.get(overrides, :status, "pending"),
      redirect_uri: Map.get(overrides, :redirect_uri),
      device_user_code: Map.get(overrides, :device_user_code),
      verification_uri: Map.get(overrides, :verification_uri),
      interval_seconds: Map.get(overrides, :interval_seconds),
      expires_at: Map.get(overrides, :expires_at, DateTime.add(DateTime.utc_now(), 600, :second)),
      poll_after_at: Map.get(overrides, :poll_after_at),
      completed_at: Map.get(overrides, :completed_at),
      cancelled_at: Map.get(overrides, :cancelled_at),
      last_polled_at: Map.get(overrides, :last_polled_at),
      result_upstream_identity_id: Map.get(overrides, :result_upstream_identity_id),
      error_code: Map.get(overrides, :error_code),
      error_message: Map.get(overrides, :error_message),
      metadata: Map.get(overrides, :metadata, %{}),
      inserted_at: Map.get(overrides, :inserted_at),
      updated_at: Map.get(overrides, :updated_at),
      state_token: Map.get(overrides, :state_token),
      code_verifier: Map.get(overrides, :code_verifier),
      device_auth_id: Map.get(overrides, :device_auth_id)
    }
  end

  defp fixture_owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end

  defp fixture_unassigned_admin_scope do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    Scope.for_user(admin)
  end

  defp authorization_state(authorization_url) do
    authorization_url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("state")
  end

  defp restore_codex_auth_config! do
    previous = Application.get_env(:codex_pooler, CodexAuth)

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexAuth, previous)
      else
        Application.delete_env(:codex_pooler, CodexAuth)
      end
    end)
  end

  defp start_provider!(routes) do
    {:ok, provider} = FakeOpenAIAuthProvider.start_link(routes)
    Application.put_env(:codex_pooler, CodexAuth, issuer: FakeOpenAIAuthProvider.url(provider))
    on_exit(fn -> FakeOpenAIAuthProvider.stop(provider) end)
    provider
  end

  defp user_fixture do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.operator_create_changeset(%{
      "email" => "oauth-flow-user-#{unique}@example.com",
      "display_name" => "OAuth Flow User",
      "password" => "bootstrap-pass-123",
      "password_change_required" => false
    })
    |> Repo.insert!()
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end
end
