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

  # Where a test process keeps the owners it bootstrapped, so a later call in the same test can tell
  # them from an owner another test committed and left behind.
  @committed_owner_key {__MODULE__, :committed_bootstrap_owner}
  @bootstrap_owner_ids_key {__MODULE__, :bootstrap_owner_ids}

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
  committed owner that test leaked: this raises instead of handing it out, and so does
  `bootstrap_owner_fixture/1`, whose silent reuse is how such a leak used to go unnoticed.
  """
  def committed_bootstrap_owner_fixture!(attrs \\ %{}) do
    key = @committed_owner_key

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

  @doc """
  Deletes, with their graph, the fixture owners among `user_ids` that no row references any more.

  `PoolerFixtures.api_key_fixture/2` commits a `pooler-N@example.com` instance owner when the
  instance has none, and records it only as its keys' creator; the committed fixtures of one test
  share it. The cleanup that removes the last row it created therefore removes the owner too,
  through `delete_user_graph!/1`, which also takes the `api_key.create` audit rows it authored.
  Other users, and fixture owners something still references, are left alone.
  """
  def delete_unreferenced_fixture_owners!(user_ids) when is_list(user_ids) do
    user_ids
    |> fixture_owner_ids()
    |> Enum.reject(&referenced_user?/1)
    |> delete_user_graph!()
  end

  defp fixture_owner_ids([]), do: []

  defp fixture_owner_ids(user_ids) do
    Repo.all(
      from user in User,
        where: user.id in ^Enum.uniq(user_ids) and like(user.email, "pooler-%@example.com"),
        select: user.id
    )
  end

  # Any creator reference keeps the owner, except the membership it granted itself.
  defp referenced_user?(user_id) do
    dumped_user_id = Ecto.UUID.dump!(user_id)

    Repo.exists?(from state in PlatformBootstrapState, where: state.owner_user_id == ^user_id) or
      Enum.any?([{"pools", :created_by_user_id} | @creator_references], fn
        {"memberships", column} ->
          Repo.exists?(
            from row in "memberships",
              where: field(row, ^column) == ^dumped_user_id and row.user_id != ^dumped_user_id
          )

        {table, column} ->
          Repo.exists?(from row in table, where: field(row, ^column) == ^dumped_user_id)
      end)
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

  @doc """
  Bootstraps an owner inside the calling test's sandbox.

  The singleton admits one owner, so a later call in the same test logs the owner already there in
  again and returns it. It raises instead of handing an owner out in the two cases that used to pass
  silently and hide a leak:

    * the singleton is completed by a committed owner this test did not create, which an earlier
      test committed and left behind (findings#193 A3: a later test asking for its own email got
      the leaked owner and passed);
    * the caller names an email and the owner this test already has carries another one.

  Called outside the sandbox, inside `Sandbox.unboxed_run/2` or in `Sandbox.mode(Repo, :auto)`, the
  owner it creates is committed and nothing removes it: use `committed_bootstrap_owner_fixture!/1`
  there.
  """
  def bootstrap_owner_fixture(attrs \\ %{}) do
    requested_email = attrs |> Map.new() |> requested_email()
    attrs = valid_bootstrap_attributes(attrs)

    case Accounts.bootstrap_owner(attrs) do
      {:ok, %{user: %User{id: user_id}} = result} ->
        Process.put(@bootstrap_owner_ids_key, [
          user_id | Process.get(@bootstrap_owner_ids_key, [])
        ])

        result

      {:error, :bootstrap_already_completed} ->
        existing_owner_session_fixture!(attrs, requested_email)

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

  defp requested_email(attrs), do: Map.get(attrs, "email") || Map.get(attrs, :email)

  defp existing_owner_session_fixture!(attrs, requested_email) do
    state = Repo.get!(PlatformBootstrapState, true)
    user = existing_owner_user!(state)
    ensure_owner_of_this_test!(state, user)
    ensure_requested_email!(user, requested_email)

    # Rewriting a singleton that is already completed would lock it inside the sandbox, and a
    # committed owner's registered removal would then wait on that lock.
    if state.status != "completed", do: complete_bootstrap_state!(user)

    password = Map.get(attrs, "password") || Map.get(attrs, :password) || valid_user_password()

    {:ok, %{user: reloaded_user, session: session, token: token}} =
      Accounts.login_user(%{"email" => user.email, "password" => password})

    %{user: reloaded_user, session: session, token: token}
  end

  defp existing_owner_user!(%PlatformBootstrapState{owner_user_id: nil} = state) do
    raise "bootstrap_owner_fixture/1: the bootstrap singleton is #{state.status} with no owner " <>
            "user, which no call of this fixture leaves; an earlier test left it that way"
  end

  defp existing_owner_user!(%PlatformBootstrapState{owner_user_id: owner_user_id} = state) do
    Repo.one(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          user.id == ^owner_user_id and membership.role == "instance_owner" and
            membership.status == "active" and
            is_nil(user.deleted_at),
        limit: 1
    ) ||
      raise "bootstrap_owner_fixture/1: the bootstrap singleton is #{state.status} for owner " <>
              "user #{owner_user_id}, which is not an active instance owner; an earlier test " <>
              "left the singleton behind"
  end

  defp ensure_owner_of_this_test!(state, %User{id: user_id}) do
    if created_in_this_test?(user_id) or not committed_user?(user_id) do
      :ok
    else
      raise """
      bootstrap_owner_fixture/1: the bootstrap singleton is #{state.status} by committed owner \
      user #{user_id} (completed at #{inspect(state.completed_at)}), which this test did not create.
      An earlier test committed that owner outside the sandbox and left it behind; handing it out \
      would hide the leak. Commit owners through committed_bootstrap_owner_fixture!/1, which \
      registers their removal, and call this fixture only inside the sandbox.
      """
    end
  end

  # An owner this fixture or `committed_bootstrap_owner_fixture!/1` created for the test process or
  # for a process it started: a `Task` carries the test process in `$callers`.
  defp created_in_this_test?(user_id) do
    Enum.any?([self() | Process.get(:"$callers", [])], fn pid ->
      match?(%{user: %User{id: ^user_id}}, dictionary_value(pid, @committed_owner_key)) or
        user_id in List.wrap(dictionary_value(pid, @bootstrap_owner_ids_key))
    end)
  end

  defp dictionary_value(pid, key) when pid == self(), do: Process.get(key)

  defp dictionary_value(pid, key) when is_pid(pid) and node(pid) == node() do
    case :erlang.process_info(pid, {:dictionary, key}) do
      {{:dictionary, ^key}, :undefined} -> nil
      {{:dictionary, ^key}, value} -> value
      :undefined -> nil
    end
  end

  defp dictionary_value(_process, _key), do: nil

  # Read over a connection of its own: inside the sandbox, that tells an owner committed before the
  # test began from one created within its transaction.
  defp committed_user?(user_id) do
    run_unboxed(fn -> Repo.exists?(from user in User, where: user.id == ^user_id) end)
  end

  defp ensure_requested_email!(_user, nil), do: :ok

  defp ensure_requested_email!(%User{id: user_id, email: email}, requested_email) do
    if String.downcase(email) == requested_email |> to_string() |> String.downcase() do
      :ok
    else
      raise "bootstrap_owner_fixture/1: this test already has owner user #{user_id}, with " <>
              "another email than the one requested; the singleton admits one owner, so use the " <>
              "owner the first call returned instead of asking for a second one"
    end
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
