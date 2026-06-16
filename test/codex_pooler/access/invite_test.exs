defmodule CodexPooler.Access.InviteTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.Invite
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Repo

  test "create_invite stores only a hashed token and returns the raw token once" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    assert {:ok, %{invite: invite, token: token}} =
             Access.create_invite(scope, pool, %{"invited_email" => "Invitee@Example.COM"})

    refute token == ""
    assert invite.invited_email == "invitee@example.com"
    assert DateTime.diff(invite.expires_at, invite.created_at, :second) == 24 * 60 * 60
    assert invite.token_hash == Access.hash_invite_token(token)
    refute inspect(invite) =~ token
  end

  test "load_usable_invite_contract rejects accepted invites" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    {:ok, %{invite: invite, token: token}} =
      Access.create_invite(scope, pool, %{invited_email: "consumed@example.com"})

    invite
    |> Invite.changeset(%{
      status: "accepted",
      accepted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert {:error, %{code: :invite_consumed}} = Access.load_usable_invite_contract(token)
  end

  test "create_invite requires an invited email" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    assert {:error, changeset} = Access.create_invite(scope, pool, %{})
    assert %{invited_email: ["can't be blank"]} = errors_on(changeset)

    assert {:error, changeset} =
             Access.create_invite(scope, pool, %{invited_email: "not-an-email"})

    assert %{invited_email: ["must be a valid email address"]} = errors_on(changeset)
  end

  test "create_invite rejects a duplicate active invite for the same Pool and email" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    assert {:ok, %{invite: invite}} =
             Access.create_invite(scope, pool, %{invited_email: "Duplicate@Example.COM"})

    assert {:error, %{code: :invite_exists, message: message}} =
             Access.create_invite(scope, pool, %{invited_email: "duplicate@example.com"})

    assert message == "An active invite already exists for this Codex account and Pool."
    assert [^invite] = Repo.all(Invite)
  end

  test "create_invite expires stale active duplicates before creating a replacement" do
    pool = pool_fixture()
    scope = fixture_owner_scope()
    expired_at = DateTime.utc_now() |> DateTime.add(-60, :second)

    {:ok, %{invite: stale}} =
      Access.create_invite(scope, pool, %{
        invited_email: "stale@example.com",
        expires_at: expired_at
      })

    assert {:ok, %{invite: replacement}} =
             Access.create_invite(scope, pool, %{invited_email: "stale@example.com"})

    assert replacement.id != stale.id
    assert Repo.reload!(stale).status == "expired"
    assert Repo.reload!(replacement).status == "active"
  end

  test "reissue_invite revokes the active invite and creates a fresh replacement" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "reissue@example.com"})

    assert {:ok, %{revoked: revoked, invite: replacement, token: token, pool: ^pool}} =
             Access.reissue_invite(scope, invite.id)

    assert revoked.id == invite.id
    assert revoked.status == "revoked"
    assert replacement.id != invite.id
    assert replacement.pool_id == pool.id
    assert replacement.invited_email == "reissue@example.com"
    assert replacement.status == "active"
    assert DateTime.diff(replacement.expires_at, replacement.created_at, :second) == 24 * 60 * 60
    assert replacement.token_hash == Access.hash_invite_token(token)
    refute inspect(replacement) =~ token
  end

  test "load_usable_invite_contract rejects accepted invites even with future expiry" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    {:ok, %{invite: invite, token: token}} =
      Access.create_invite(scope, pool, %{
        invited_email: "future-consumed@example.com",
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      })

    invite
    |> Invite.changeset(%{
      status: "accepted",
      accepted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert {:error, %{code: :invite_consumed}} = Access.load_usable_invite_contract(token)
  end

  test "load_usable_invite_contract returns public pool-scoped onboarding contract" do
    pool = pool_fixture(%{slug: "sample-pool", name: "Sample Pool"})
    scope = fixture_owner_scope()

    {:ok, %{token: token}} =
      Access.create_invite(scope, pool, %{
        invited_email: "invited@example.com",
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      })

    assert {:ok, %{invite: contract}} = Access.load_usable_invite_contract(token)
    assert contract.pool_slug == "sample-pool"
    assert contract.invited_email == "invited@example.com"
    assert contract.inviter_label == scope.user.email
    assert contract.expires_at
    assert contract.available_methods == ["device"]
    assert contract.wizard_path == "/onboarding/invites/#{token}"
    refute Map.has_key?(contract, :onboarding_api_path)
  end

  test "load_usable_invite_contract falls back to safe operator label when inviter is absent" do
    pool = pool_fixture(%{slug: "fallback-pool", name: "Fallback Pool"})
    scope = fixture_owner_scope()

    {:ok, %{invite: nil_inviter, token: nil_token}} =
      Access.create_invite(scope, pool, %{invited_email: "nil-inviter@example.com"})

    {:ok, %{invite: deleted_inviter, token: deleted_token}} =
      Access.create_invite(scope, pool, %{invited_email: "deleted-inviter@example.com"})

    nil_inviter
    |> Invite.changeset(%{created_by_user_id: nil, updated_at: DateTime.utc_now()})
    |> Repo.update!()

    scope.user
    |> User.operator_update_changeset(%{email: scope.user.email})
    |> Ecto.Changeset.put_change(:deleted_at, DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, %{invite: %{inviter_label: "iCoreTech operator"}}} =
             Access.load_usable_invite_contract(nil_token)

    assert {:ok, %{invite: %{inviter_label: "iCoreTech operator"}}} =
             Access.load_usable_invite_contract(deleted_token)

    assert Repo.get!(Invite, deleted_inviter.id).created_by_user_id == scope.user.id
  end

  test "consume_invite returns an error instead of raising when upstream identity is missing" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "missing-identity@example.com"})

    assert {:error, %{code: :invalid_request, message: "upstream_identity_id is required"}} =
             Access.consume_invite(invite, %{})

    assert Repo.get!(Invite, invite.id).status == "active"
  end

  test "consume_invite records acceptance and marks invite accepted" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "accepted@example.com"})

    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool)

    assert {:ok, %{invite: accepted, acceptance: acceptance}} =
             Access.consume_invite(invite, %{
               "upstream_identity_id" => identity.id,
               "pool_upstream_assignment_id" => assignment.id,
               "accepted_by_email" => "accepted@example.com"
             })

    assert accepted.status == "accepted"
    assert accepted.accepted_at
    assert acceptance.invite_id == invite.id
    assert acceptance.pool_id == pool.id
    assert acceptance.upstream_identity_id == identity.id
    assert acceptance.pool_upstream_assignment_id == assignment.id
    assert acceptance.accepted_by_email == "accepted@example.com"
  end

  test "list_invites returns operator-facing invite rows" do
    pool = pool_fixture(%{slug: "invite-rows", name: "Invite Rows"})
    scope = fixture_owner_scope()

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "listed@example.com"})

    assert {:ok, %{items: [row], total: 1}} = Access.list_invites(scope)
    assert row.id == invite.id
    assert row.pool_name == "Invite Rows"
    assert row.pool_slug == "invite-rows"
    assert row.invited_email == "listed@example.com"
    assert row.inviter_email == scope.user.email
    assert row.status == "active"
  end

  test "list_invites rejects invalid scope while visible invite listing falls back to an empty page" do
    assert {:error, %{code: :invalid_request}} = Access.list_invites(nil)
    assert {:error, %{code: :invalid_request}} = Access.list_invites(%{})

    assert %{items: [], total: 0, limit: 25} = Access.list_visible_invites(nil, limit: 25)
  end

  test "list_invites projects expired active invites as expired rows" do
    pool = pool_fixture(%{slug: "expired-invite-rows", name: "Expired Invite Rows"})
    scope = fixture_owner_scope()

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "expired-row@example.com"})

    expired_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    invite
    |> Invite.changeset(%{expires_at: expired_at})
    |> Repo.update!()

    assert {:ok, %{items: [row], total: 1}} =
             Access.list_invites(scope, filters: [status: "expired"])

    assert row.id == invite.id
    assert row.status == "expired"
    assert row.stored_status == "active"
  end

  test "revoke_invite marks active invite revoked and records audit event" do
    pool = pool_fixture()
    scope = fixture_owner_scope()

    {:ok, %{invite: invite}} =
      Access.create_invite(scope, pool, %{invited_email: "revoke@example.com"})

    assert {:ok, revoked} = Access.revoke_invite(scope, invite.id)
    assert revoked.status == "revoked"
    assert revoked.revoked_at

    assert {:ok, %{items: [row]}} = Access.list_invites(scope, filters: [status: "revoked"])
    assert row.id == invite.id

    assert Repo.get_by(CodexPooler.Audit.AuditEvent,
             action: "invite.revoke",
             target_id: invite.id
           )
  end

  test "assigned admins list and create invites only for assigned pools" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    pool_a = pool_fixture(%{name: "Pool A"})
    pool_b = pool_fixture(%{name: "Pool B"})
    pool_c = pool_fixture(%{name: "Pool C"})

    operator_pool_assignment_fixture(admin, pool_a, created_by_user_id: owner.id)
    operator_pool_assignment_fixture(admin, pool_b, created_by_user_id: owner.id)
    admin_scope = Scope.for_user(admin)

    {:ok, %{invite: invite_a}} =
      Access.create_invite(owner_scope, pool_a, %{invited_email: "a@example.com"})

    {:ok, %{invite: invite_b}} =
      Access.create_invite(owner_scope, pool_b, %{invited_email: "b@example.com"})

    {:ok, %{invite: _invite_c}} =
      Access.create_invite(owner_scope, pool_c, %{invited_email: "c@example.com"})

    assert {:ok, %{invite: created}} =
             Access.create_invite(admin_scope, pool_a, %{invited_email: "admin-a@example.com"})

    assert {:error, %{code: :capability_denied}} =
             Access.create_invite(admin_scope, pool_c, %{invited_email: "admin-c@example.com"})

    assert {:ok, %{items: rows, total: 3}} = Access.list_invites(admin_scope)

    assert Enum.map(rows, & &1.id) |> Enum.sort() ==
             Enum.sort([created.id, invite_a.id, invite_b.id])

    assert {:ok, %{items: [], total: 0}} =
             Access.list_invites(admin_scope, filters: [pool_id: pool_c.id])
  end

  test "unassigned admins cannot list create reissue or revoke pool invites" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    pool = pool_fixture(%{name: "Hidden Invite Pool"})

    {:ok, %{invite: invite}} =
      Access.create_invite(owner_scope, pool, %{invited_email: "hidden-invite@example.com"})

    admin_scope = Scope.for_user(admin)

    assert {:ok, %{items: [], total: 0}} = Access.list_invites(admin_scope)

    assert {:error, %{code: :capability_denied}} =
             Access.create_invite(admin_scope, pool, %{invited_email: "denied@example.com"})

    assert {:error, %{code: :capability_denied}} = Access.reissue_invite(admin_scope, invite.id)
    assert {:error, %{code: :capability_denied}} = Access.revoke_invite(admin_scope, invite.id)
    assert Repo.get!(Invite, invite.id).status == "active"
  end

  test "assigned admins cannot reissue or revoke unassigned pool invites" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    pool_a = pool_fixture(%{name: "Pool A"})
    pool_c = pool_fixture(%{name: "Pool C"})

    operator_pool_assignment_fixture(admin, pool_a, created_by_user_id: owner.id)
    admin_scope = Scope.for_user(admin)

    {:ok, %{invite: assigned_invite}} =
      Access.create_invite(owner_scope, pool_a, %{invited_email: "assigned@example.com"})

    {:ok, %{invite: hidden_invite}} =
      Access.create_invite(owner_scope, pool_c, %{invited_email: "hidden@example.com"})

    assert {:ok, %{revoked: revoked}} = Access.reissue_invite(admin_scope, assigned_invite.id)
    assert revoked.id == assigned_invite.id

    assert {:error, %{code: :capability_denied}} =
             Access.reissue_invite(admin_scope, hidden_invite.id)

    assert {:error, %{code: :capability_denied}} =
             Access.revoke_invite(admin_scope, hidden_invite.id)

    assert Repo.get!(Invite, hidden_invite.id).status == "active"
  end

  defp fixture_owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end
end
