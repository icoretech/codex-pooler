defmodule CodexPooler.AccountsFixtures do
  @moduledoc """
  Helpers for creating account fixtures through the public Accounts context.
  """

  import Ecto.Query
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1, run_unboxed: 1]

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{PlatformBootstrapState, User}
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  # The references to `users` that carry no `ON DELETE` rule, other than the audit actor and the
  # bootstrap owner handled on their own: a user cannot be deleted while any of these points at it.
  # `pools` is not listed because `delete_user_graph!/1` deletes a user's Pools first, and they
  # cascade to most of what hangs off them.
  @creator_references [
    {"api_keys", :created_by_user_id},
    {"upstream_identities", :created_by_user_id},
    {"pool_upstream_assignments", :created_by_user_id},
    {"invites", :created_by_user_id},
    {"operator_pool_assignments", :created_by_user_id},
    {"upstream_oauth_flows", :requested_by_user_id},
    {"memberships", :created_by_user_id}
  ]

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "bootstrap-pass-123"

  def valid_bootstrap_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "display_name" => "Owner",
      "email" => "owner@example.com",
      "password" => valid_user_password()
    })
  end

  @doc """
  Returns the instance to its unbootstrapped state inside the calling test's sandbox.

  Deletes every user the test can see, with the rows `delete_user_graph!/1` removes alongside
  them, and replaces the bootstrap singleton with a `pending` row.

  Sandbox only: there the deletes roll back with the test. Run unboxed, it would delete users other
  files committed, which is how a leaked owner used to disappear without a trace, and the
  `TRUNCATE users CASCADE` this replaced also emptied fifty-odd unrelated tables, the committed
  `instance_settings` singleton among them. A committed fixture removes exactly what it commits
  through `committed_bootstrap_owner_fixture!/1` instead.
  """
  def reset_bootstrap_state_fixture! do
    User |> select([user], user.id) |> Repo.all() |> delete_user_graph!()
    Repo.delete_all(PlatformBootstrapState)
    Repo.insert!(%PlatformBootstrapState{singleton: true, status: "pending"})
  end

  @doc """
  Commits a bootstrap owner outside the sandbox and registers the removal of everything it owns.

  Call it from the test process, before registering cleanup for rows the owner goes on to create,
  so that its own removal runs last. The removal is registered before the commit and keyed on the
  email, which is derived per call unless `attrs` names one, so a bootstrap that fails partway
  through is covered too. It deletes the owner through `delete_user_graph!/1`, which also returns
  the bootstrap singleton to `pending`.

  The singleton admits a single owner, so a later call in the same test returns the owner the
  first call committed and ignores its own `attrs`. A singleton that another test completed is a
  committed owner that test leaked: this raises instead of handing it out, which is what
  `bootstrap_owner_fixture/1` does and why such a leak used to go unnoticed.
  """
  def committed_bootstrap_owner_fixture!(attrs \\ %{}) do
    key = {__MODULE__, :committed_bootstrap_owner}

    case Process.get(key) do
      %{user: %User{}} = committed -> committed
      nil -> commit_bootstrap_owner!(key, attrs)
    end
  end

  defp commit_bootstrap_owner!(key, attrs) do
    attrs =
      attrs |> Map.put_new_lazy("email", &unique_user_email/0) |> valid_bootstrap_attributes()

    email = Map.fetch!(attrs, "email")
    register_unboxed_cleanup!(fn -> delete_users_by_email!([email]) end)

    case run_unboxed(fn -> Accounts.bootstrap_owner(attrs) end) do
      {:ok, committed} ->
        Process.put(key, committed)
        committed

      {:error, :bootstrap_already_completed} ->
        raise "committed_bootstrap_owner_fixture!/1: the committed bootstrap singleton is " <>
                "already completed by an owner this test did not commit; an earlier test leaked it"

      {:error, %Ecto.Changeset{} = changeset} ->
        raise "committed_bootstrap_owner_fixture!/1 failed: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Deletes `user_ids` and every row that cannot outlive them, on the calling connection.

  In order:

    * the users whose memberships one of them granted join the set, repeatedly;
    * the bootstrap singleton goes back to `pending` when one of them owns it;
    * the audit rows they authored or that their Pools carry are deleted, since a Pool delete
      only clears `audit_events.pool_id`;
    * the Pools they created are deleted, cascading to API keys, sessions, requests, models and
      assignments, and so are the upstream identities those Pools held that no other Pool does;
    * every other row they created through a reference with no delete rule is deleted;
    * the users are deleted, cascading to memberships, sessions and their other account rows.

  Rows with no path to the users, such as an identity created without a creator and never
  assigned, a pricing snapshot or the instance settings row, stay the caller's to remove.
  """
  def delete_user_graph!(user_ids) when is_list(user_ids) do
    case expand_granted_users(Enum.uniq(user_ids)) do
      [] -> :ok
      user_ids -> delete_expanded_user_graph!(user_ids)
    end
  end

  defp delete_users_by_email!(emails) do
    User
    |> where([user], user.email in ^emails)
    |> select([user], user.id)
    |> Repo.all()
    |> delete_user_graph!()
  end

  defp expand_granted_users([]), do: []

  defp expand_granted_users(user_ids) do
    granted =
      Repo.all(
        from membership in Membership,
          where:
            membership.created_by_user_id in ^user_ids and membership.user_id not in ^user_ids,
          distinct: true,
          select: membership.user_id
      )

    case granted do
      [] -> user_ids
      granted -> expand_granted_users(user_ids ++ granted)
    end
  end

  defp delete_expanded_user_graph!(user_ids) do
    dumped_user_ids = Enum.map(user_ids, &Ecto.UUID.dump!/1)

    pool_ids =
      Repo.all(
        from pool in "pools", where: pool.created_by_user_id in ^dumped_user_ids, select: pool.id
      )

    identity_ids =
      Repo.all(
        from assignment in "pool_upstream_assignments",
          where: assignment.pool_id in ^pool_ids,
          distinct: true,
          select: assignment.upstream_identity_id
      )

    Repo.update_all(
      from(state in PlatformBootstrapState, where: state.owner_user_id in ^user_ids),
      set: [status: "pending", owner_user_id: nil, completed_at: nil]
    )

    Repo.delete_all(
      from event in "audit_events",
        where: event.actor_user_id in ^dumped_user_ids or event.pool_id in ^pool_ids
    )

    Repo.delete_all(from pool in "pools", where: pool.id in ^pool_ids)

    Repo.delete_all(
      from identity in "upstream_identities",
        as: :identity,
        where:
          identity.id in ^identity_ids and
            not exists(
              from assignment in "pool_upstream_assignments",
                where: assignment.upstream_identity_id == parent_as(:identity).id,
                select: 1
            )
    )

    for {table, column} <- @creator_references do
      Repo.delete_all(from row in table, where: field(row, ^column) in ^dumped_user_ids)
    end

    Repo.delete_all(from user in User, where: user.id in ^user_ids)
    :ok
  end

  def bootstrap_owner_fixture(attrs \\ %{}) do
    attrs = valid_bootstrap_attributes(attrs)

    case Accounts.bootstrap_owner(attrs) do
      {:ok, result} ->
        result

      {:error, :bootstrap_already_completed} ->
        existing_owner_session_fixture!(attrs)

      {:error, %Ecto.Changeset{} = changeset} ->
        raise "bootstrap_owner_fixture failed: #{inspect(changeset.errors)}"
    end
  end

  def valid_operator_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "display_name" => "Operator",
      "email" => unique_user_email(),
      "temporary_password" => valid_user_password()
    })
  end

  def operator_metadata(attrs \\ %{}) do
    Enum.into(attrs, %{
      ip_address: "203.0.113.30",
      user_agent: "operator-test"
    })
  end

  def operator_fixture(actor, attrs \\ %{}, metadata \\ %{}) do
    {:ok, result} =
      Accounts.create_operator(
        actor,
        valid_operator_attributes(attrs),
        operator_metadata(metadata)
      )

    result
  end

  defp existing_owner_session_fixture!(attrs) do
    password = Map.get(attrs, "password") || Map.get(attrs, :password) || valid_user_password()
    user = existing_owner_user!()
    complete_bootstrap_state!(user)

    {:ok, %{user: reloaded_user, session: session, token: token}} =
      Accounts.login_user(%{"email" => user.email, "password" => password})

    %{user: reloaded_user, session: session, token: token}
  end

  defp existing_owner_user! do
    owner_user_id =
      PlatformBootstrapState
      |> Repo.get!(true)
      |> Map.fetch!(:owner_user_id)

    Repo.one!(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          user.id == ^owner_user_id and membership.role == "instance_owner" and
            membership.status == "active" and
            is_nil(user.deleted_at),
        limit: 1
    )
  end

  defp complete_bootstrap_state!(user) do
    now = DateTime.utc_now()

    PlatformBootstrapState
    |> Repo.get!(true)
    |> Ecto.Changeset.change(
      status: "completed",
      owner_user_id: user.id,
      completed_at: now,
      updated_at: now
    )
    |> Repo.update!()
  end
end
