defmodule CodexPooler.AccountsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.AuditLog
  alias CodexPooler.Accounts.{RecoveryCode, Session, TOTPSetting, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures

  setup do
    reset_bootstrap_state_fixture!()
    :ok
  end

  describe "bootstrap_owner/2" do
    test "creates exactly one instance owner, membership, session, and audit row" do
      assert Accounts.bootstrap_status() == "pending"

      assert {:ok, %{user: %User{} = user, token: token}} =
               Accounts.bootstrap_owner(
                 valid_bootstrap_attributes(%{"email" => "Owner@Example.com"}),
                 %{
                   ip_address: "203.0.113.10",
                   user_agent: "test-agent"
                 }
               )

      assert user.email == "owner@example.com"
      assert Accounts.bootstrap_status() == "completed"

      assert Accounts.get_user_by_email_and_password("OWNER@example.com", valid_user_password()).id ==
               user.id

      assert Repo.get_by(Membership, user_id: user.id, role: "instance_owner", status: "active")
      assert Repo.one(from s in Session, where: s.user_id == ^user.id and s.status == "active")
      assert Accounts.get_user_by_session_token(token)
      assert Repo.get_by(AuditEvent, action: "auth.bootstrap", actor_user_id: user.id)

      assert {:error, :bootstrap_already_completed} =
               Accounts.bootstrap_owner(
                 valid_bootstrap_attributes(%{"email" => "second@example.com"})
               )
    end

    test "serializes concurrent bootstrap attempts through the singleton lock" do
      parent = self()

      tasks =
        for idx <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Accounts.bootstrap_owner(
              valid_bootstrap_attributes(%{"email" => "owner-#{idx}@example.com"})
            )
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :bootstrap_already_completed})) == 1
      assert Repo.aggregate(Membership, :count) == 1
    end
  end

  describe "login_user/2" do
    test "rejects invalid credentials safely and creates sessions for valid credentials" do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:error, :invalid_credentials} =
               Accounts.login_user(%{"email" => user.email, "password" => "wrong-password"})

      assert {:ok, %{user: logged_in, token: token}} =
               Accounts.login_user(%{
                 "email" => "OWNER@example.com",
                 "password" => valid_user_password()
               })

      assert logged_in.id == user.id
      assert Accounts.get_user_by_session_token(token)
      assert Repo.get_by(AuditEvent, action: "auth.login", actor_user_id: user.id)
    end

    test "requires TOTP and consumes recovery codes only once" do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      {:ok, %{secret: secret, recovery_codes: [recovery_code | _]}} =
        Accounts.enable_totp_for_user(user)

      setting = Repo.get_by!(TOTPSetting, user_id: user.id)
      assert setting.status == "active"
      refute setting.secret_ciphertext == secret
      assert Repo.aggregate(from(c in RecoveryCode, where: c.user_id == ^user.id), :count) == 10

      assert {:error, :totp_required} =
               Accounts.login_user(%{"email" => user.email, "password" => valid_user_password()})

      assert {:ok, %{token: recovery_token}} =
               Accounts.complete_second_factor_login(user.id, %{"recovery_code" => recovery_code})

      assert Accounts.get_user_by_session_token(recovery_token)

      assert {:error, :invalid_recovery_code} =
               Accounts.login_user(%{
                 "email" => user.email,
                 "password" => valid_user_password(),
                 "recovery_code" => recovery_code
               })

      assert {:ok, %{token: totp_token}} =
               Accounts.complete_second_factor_login(user.id, %{
                 "totp_code" => Accounts.current_totp_code(secret)
               })

      assert Accounts.get_user_by_session_token(totp_token)
      assert Repo.get_by(AuditEvent, action: "auth.recovery_code_used", actor_user_id: user.id)
    end
  end

  describe "delete_user_session_token/1" do
    test "get_user_by_session_token reads without touching session state" do
      %{user: user, token: token} = bootstrap_owner_fixture()

      session =
        Repo.one!(from s in Session, where: s.user_id == ^user.id and s.status == "active")

      assert is_nil(session.last_seen_at)

      assert Accounts.get_user_by_session_token(token)
      assert is_nil(Repo.reload!(session).last_seen_at)

      assert Accounts.authenticate_session_token(token)
      assert %DateTime{} = Repo.reload!(session).last_seen_at
    end

    test "revokes a stored operator session" do
      %{token: token} = bootstrap_owner_fixture()

      assert Accounts.get_user_by_session_token(token)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end

    test "lists active browser sessions and revokes other sessions" do
      %{user: user, token: current_token} =
        bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, %{token: other_token}} =
               Accounts.login_user(
                 %{
                   "email" => user.email,
                   "password" => valid_user_password()
                 },
                 %{user_agent: "Parallel Browser", ip_address: "203.0.113.44"}
               )

      sessions = Accounts.list_user_sessions(user, current_token)

      assert Enum.count(sessions) == 2
      assert [current_session] = Enum.filter(sessions, & &1.current?)
      assert current_session.user_agent in [nil, ""]

      assert [other_session] = Enum.reject(sessions, & &1.current?)
      assert other_session.user_agent == "Parallel Browser"
      assert other_session.ip_address == "203.0.113.44"
      refute Map.has_key?(other_session, :session_token_hash)

      assert {:ok, 1} =
               Accounts.revoke_other_user_sessions(user, current_token, %{
                 request_id: "revoke-other-sessions"
               })

      assert Accounts.get_user_by_session_token(current_token)
      refute Accounts.get_user_by_session_token(other_token)
      assert Repo.get_by(AuditEvent, action: "auth.sessions_revoked", actor_user_id: user.id)
    end

    test "revokes one active browser session by id" do
      %{user: user, token: current_token} =
        bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, %{token: other_token}} =
               Accounts.login_user(
                 %{"email" => user.email, "password" => valid_user_password()},
                 %{user_agent: "Other Browser", ip_address: "198.51.100.44"}
               )

      [other_session] =
        user
        |> Accounts.list_user_sessions(current_token)
        |> Enum.reject(& &1.current?)

      assert {:ok, %{current?: false, revoked_count: 1}} =
               Accounts.revoke_user_session(user, other_session.id, current_token, %{
                 request_id: "revoke-one-session"
               })

      assert Accounts.get_user_by_session_token(current_token)
      refute Accounts.get_user_by_session_token(other_token)
      assert Repo.get_by(AuditEvent, action: "auth.session_revoked", actor_user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "updates the password, rotates sessions, and audits the change" do
      %{user: user, token: bootstrap_token} =
        bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, %{token: login_token}} =
               Accounts.login_user(%{
                 "email" => user.email,
                 "password" => valid_user_password()
               })

      assert Accounts.get_user_by_session_token(bootstrap_token)
      assert Accounts.get_user_by_session_token(login_token)

      assert {:ok, %{user: changed_user, token: rotated_token}} =
               Accounts.change_user_password(
                 user,
                 %{"new_password" => "new-bootstrap-pass-456"},
                 %{ip_address: "203.0.113.20", user_agent: "test-agent"}
               )

      assert changed_user.id == user.id
      refute rotated_token in [bootstrap_token, login_token]
      refute Accounts.get_user_by_session_token(bootstrap_token)
      refute Accounts.get_user_by_session_token(login_token)
      assert Accounts.get_user_by_session_token(rotated_token)

      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      assert Accounts.get_user_by_email_and_password(user.email, "new-bootstrap-pass-456").id ==
               user.id

      assert Repo.get_by(AuditEvent, action: "auth.password_change", actor_user_id: user.id)

      assert Repo.aggregate(
               from(s in Session, where: s.user_id == ^user.id and s.status == "active"),
               :count
             ) == 1
    end

    test "rejects invalid new passwords without mutating the stored hash" do
      %{user: user, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.change_user_password(user, %{"new_password" => "short"})

      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)

      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      assert Accounts.get_user_by_session_token(token)
      refute Repo.get_by(AuditEvent, action: "auth.password_change", actor_user_id: user.id)
    end
  end

  describe "audit log wrapper" do
    test "records attrs-map events and normalizes request metadata" do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, event} =
               AuditLog.record_user_event(user, %{
                 action: "auth.logout",
                 target_type: "session",
                 metadata: %{request_id: "audit-wrapper-request", ip_address: "203.0.113.42"},
                 details: %{reason: "manual"}
               })

      event = Repo.reload!(event)
      assert event.actor_user_id == user.id
      assert event.correlation_id == "audit-wrapper-request"
      assert event.ip_address == "203.0.113.42"
      assert event.details == %{"reason" => "manual"}
    end

    test "retains only normalized bounded ingress peer provenance" do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, event} =
               AuditLog.record_user_event(user, %{
                 action: "auth.logout",
                 target_type: "session",
                 metadata: %{
                   ingress_peer_provenance: %{
                     immediate_peer_ip: "2001:db8::42",
                     client_ip_source: :x_forwarded_for,
                     inspected_hops: 500,
                     raw_headers: %{"x-forwarded-for" => "must-not-persist"},
                     token: "must-not-persist"
                   }
                 },
                 details: %{reason: "manual"}
               })

      assert Repo.reload!(event).details == %{
               "ingress_peer_provenance" => %{
                 "client_ip_source" => "x_forwarded_for",
                 "immediate_peer_ip" => "2001:db8::42",
                 "inspected_hops" => 32
               },
               "reason" => "manual"
             }
    end

    test "omits malformed ingress peer provenance without raising" do
      %{user: user} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, event} =
               AuditLog.record_user_event(user, %{
                 action: "auth.logout",
                 target_type: "session",
                 metadata: %{
                   ingress_peer_provenance: %{
                     immediate_peer_ip: <<255, 0, 44>>,
                     client_ip_source: "x_forwarded_for",
                     inspected_hops: 2
                   }
                 },
                 details: %{reason: "manual"}
               })

      assert Repo.reload!(event).details == %{"reason" => "manual"}
    end

    test "ignores invalid actors without writing an audit row" do
      assert {:ok, nil} =
               AuditLog.record_user_event(:not_a_user, %{
                 action: "auth.logout",
                 target_type: "session"
               })

      refute Repo.get_by(AuditEvent, action: "auth.logout")
    end
  end

  describe "operator schema" do
    @tag :operator_schema
    test "persists password_change_required with a database default of false" do
      default_user =
        %User{}
        |> User.bootstrap_changeset(valid_bootstrap_attributes(%{"email" => unique_user_email()}))
        |> Repo.insert!()

      assert Repo.reload!(default_user).password_change_required == false

      required_user =
        %User{}
        |> User.bootstrap_changeset(valid_bootstrap_attributes(%{"email" => unique_user_email()}))
        |> Ecto.Changeset.put_change(:password_change_required, true)
        |> Repo.insert!()

      assert Repo.reload!(required_user).password_change_required == true
    end
  end
end
