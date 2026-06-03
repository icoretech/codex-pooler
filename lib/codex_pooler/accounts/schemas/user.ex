defmodule CodexPooler.Accounts.User do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @derive {Inspect, except: [:password]}

  @email_max_length 160
  @password_min_length 8
  @password_max_length 72

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :password_hash, :string
    field :status, :string
    field :password_change_required, :boolean, default: false
    field :datetime_format, :string
    field :timezone, :string
    field :last_login_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    field :password, :string, virtual: true, redact: true
    field :totp_status, :string, virtual: true
  end

  def bootstrap_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :display_name, :password])
    |> validate_email()
    |> validate_display_name()
    |> validate_password()
    |> put_change(:status, "active")
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_password()
  end

  def operator_create_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :display_name, :password, :password_change_required])
    |> validate_email()
    |> validate_display_name()
    |> validate_password()
    |> put_change(:status, "active")
    |> default_password_change_required(attrs)
  end

  def operator_update_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :display_name, :password_change_required])
    |> validate_email()
    |> validate_display_name()
  end

  def operator_temporary_password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_change_required])
    |> validate_password()
    |> default_password_change_required(attrs)
  end

  def valid_password?(%__MODULE__{password_hash: password_hash}, password)
      when is_binary(password_hash) and byte_size(password) > 0 do
    Argon2.verify_pass(password, password_hash)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_length(:email, max: @email_max_length)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> unique_constraint(:email, name: :users_email_active_uq)
  end

  defp validate_display_name(changeset) do
    changeset
    |> update_change(:display_name, fn
      nil -> nil
      value -> String.trim(value)
    end)
    |> validate_length(:display_name, max: 160)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: @password_min_length, max: @password_max_length)
    |> maybe_hash_password()
  end

  defp default_password_change_required(changeset, attrs) when is_map(attrs) do
    if Map.has_key?(attrs, "password_change_required") or
         Map.has_key?(attrs, :password_change_required) do
      changeset
    else
      put_change(changeset, :password_change_required, true)
    end
  end

  defp default_password_change_required(changeset, _attrs) do
    put_change(changeset, :password_change_required, true)
  end

  defp maybe_hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      put_change(changeset, :password_hash, Argon2.hash_pwd_salt(password))
    else
      changeset
    end
  end

  defp normalize_email(nil), do: nil

  defp normalize_email(email) do
    email
    |> String.trim()
    |> String.downcase()
  end
end
