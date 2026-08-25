defmodule CodexPooler.Dev.Seeds do
  @moduledoc """
  Idempotent local development seed data.

  The compact seed is safe for `mix ecto.setup`: it keeps the operator list small
  while making the app immediately sign-in capable on an empty database.

  Rich UI and performance fixtures live in scenario modules so this facade stays
  focused on the public seed modes and shared operator bootstrap.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.{PlatformBootstrapState, User}
  alias CodexPooler.Dev.Seeds.{DocsScreenshots, Full, Perf}
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  @password "dev-password-123"
  @owner_email "dev-owner@example.com"
  @type compact_result :: %{
          required(:owner) => User.t(),
          required(:operators) => [User.t()],
          required(:password) => String.t()
        }

  @operator_specs [
    %{email: "dev-admin@example.com", display_name: "Dev Admin", status: "active"},
    %{
      email: "dev-password-reset@example.com",
      display_name: "Dev Password Reset",
      status: "active",
      password_change_required: true
    },
    %{email: "dev-disabled@example.com", display_name: "Dev Disabled", status: "disabled"},
    %{email: "dev-operator@example.com", display_name: "Dev Operator", status: "active"}
  ]

  @spec compact() :: compact_result()
  def compact do
    require_dev_seeds_enabled!()

    owner = ensure_owner!()

    operators =
      Enum.map(@operator_specs, fn spec ->
        spec
        |> ensure_operator_user!()
        |> ensure_membership!("instance_admin", owner.id)
      end)

    %{owner: owner, operators: operators, password: @password}
  end

  @doc "Seeds a rich local fake dataset for exercising admin UI states."
  @spec full() :: map()
  def full do
    compact()
    |> Full.run()
  end

  @doc "Seeds deterministic public-safe data for operator documentation screenshots."
  @spec docs_screenshots() :: map()
  def docs_screenshots do
    compact()
    |> DocsScreenshots.run()
  end

  @doc "Seeds an isolated local fake dataset for gateway performance checks."
  @spec perf() :: map()
  def perf do
    require_dev_seeds_enabled!()
    owner = ensure_perf_owner!()
    Perf.run(%{owner: owner})
  end

  defp ensure_perf_owner! do
    owner = reset_owner_password!(ensure_user!(owner_spec()))
    ensure_membership!(owner, "instance_owner", owner.id)
  end

  @spec ensure_owner!() :: User.t()
  defp ensure_owner! do
    case active_owner() do
      %User{email: @owner_email} = owner ->
        reset_owner_password!(owner)

      %User{} = owner ->
        owner

      nil ->
        owner = reset_owner_password!(ensure_user!(owner_spec()))
        ensure_membership!(owner, "instance_owner", owner.id)
        complete_bootstrap!(owner)
        owner
    end
  end

  defp require_dev_seeds_enabled! do
    unless Application.get_env(:codex_pooler, :dev_seeds_enabled, false) do
      raise "development seeds are disabled for this environment"
    end
  end

  defp owner_spec, do: %{email: @owner_email, display_name: "Dev Owner", status: "active"}

  defp reset_owner_password!(%User{} = owner) do
    owner
    |> User.operator_temporary_password_changeset(%{
      password: @password,
      password_change_required: false
    })
    |> Ecto.Changeset.cast(owner_spec(), [:email, :display_name])
    |> Ecto.Changeset.put_change(:status, "active")
    |> Ecto.Changeset.put_change(:updated_at, now())
    |> Repo.update!()
  end

  @spec ensure_operator_user!(map()) :: User.t()
  defp ensure_operator_user!(spec) do
    spec
    |> Map.put_new(:password_change_required, false)
    |> ensure_user!()
  end

  @spec ensure_user!(map()) :: User.t()
  defp ensure_user!(spec) do
    now = now()
    attrs = user_attrs(spec, now)

    case Repo.get_by(User, email: spec.email) do
      %User{} = user ->
        user
        |> User.operator_temporary_password_changeset(attrs)
        |> Ecto.Changeset.cast(attrs, [:email, :display_name])
        |> Ecto.Changeset.put_change(:status, spec.status)
        |> Ecto.Changeset.put_change(:updated_at, now)
        |> Repo.update!()

      nil ->
        %User{}
        |> User.operator_create_changeset(attrs)
        |> Ecto.Changeset.put_change(:status, spec.status)
        |> Ecto.Changeset.put_change(:created_at, now)
        |> Ecto.Changeset.put_change(:updated_at, now)
        |> Repo.insert!()
    end
  end

  @spec ensure_membership!(User.t(), String.t(), Ecto.UUID.t()) :: User.t()
  defp ensure_membership!(%User{} = user, role, created_by_user_id) do
    membership = Repo.get_by(Membership, user_id: user.id, role: role, status: "active")

    if is_nil(membership) do
      %Membership{}
      |> Membership.changeset(%{
        user_id: user.id,
        role: role,
        status: "active",
        created_by_user_id: created_by_user_id,
        created_at: now()
      })
      |> Repo.insert!()
    end

    user
  end

  defp complete_bootstrap!(%User{} = owner) do
    state = Repo.get!(PlatformBootstrapState, true)
    timestamp = now()

    state
    |> Ecto.Changeset.change(%{
      status: "completed",
      owner_user_id: owner.id,
      completed_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp active_owner do
    Repo.one(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          membership.role == "instance_owner" and membership.status == "active" and
            is_nil(user.deleted_at),
        order_by: [asc: user.created_at, asc: user.id],
        limit: 1
    )
  end

  defp user_attrs(spec, timestamp) do
    %{
      email: spec.email,
      display_name: spec.display_name,
      password: @password,
      password_change_required: Map.get(spec, :password_change_required, false),
      status: spec.status,
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
