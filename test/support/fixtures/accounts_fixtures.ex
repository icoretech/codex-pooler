defmodule CodexPooler.AccountsFixtures do
  @moduledoc """
  Helpers for creating account fixtures through the public Accounts context.
  """

  import Ecto.Query

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{PlatformBootstrapState, User}
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "bootstrap-pass-123"

  def valid_bootstrap_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "display_name" => "Owner",
      "email" => "owner@example.com",
      "password" => valid_user_password()
    })
  end

  def reset_bootstrap_state_fixture! do
    Repo.delete_all(PlatformBootstrapState)
    Repo.query!("TRUNCATE TABLE users CASCADE")
    Repo.insert!(%PlatformBootstrapState{singleton: true, status: "pending"})
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
