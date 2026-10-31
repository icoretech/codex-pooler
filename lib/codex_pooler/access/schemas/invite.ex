defmodule CodexPooler.Access.Invite do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.SupportedLocales

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "invites" do
    field :pool_id, :binary_id
    field :token_hash, :binary
    field :invited_email, :string
    field :locale, :string
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :created_by_user_id, :binary_id
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :email_sent_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :pool_id,
      :token_hash,
      :invited_email,
      :locale,
      :status,
      :expires_at,
      :created_by_user_id,
      :created_at,
      :updated_at,
      :accepted_at,
      :email_sent_at,
      :revoked_at
    ])
    |> update_change(:invited_email, &normalize_email/1)
    |> validate_required([
      :pool_id,
      :token_hash,
      :invited_email,
      :status,
      :created_at,
      :updated_at
    ])
    |> validate_format(:invited_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email address")
    |> validate_inclusion(:status, ~w(active accepted revoked expired))
    |> validate_inclusion(:locale, SupportedLocales.tags())
    |> check_constraint(:locale, name: :invites_locale_check)
    |> check_constraint(:invited_email, name: :invites_invited_email_not_blank_check)
    |> unique_constraint(:token_hash, name: :invites_token_hash_uq)
    |> unique_constraint(:invited_email,
      name: :invites_active_pool_email_uq,
      message: "already has an active invite for this Pool"
    )
  end

  defp normalize_email(nil), do: nil
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
