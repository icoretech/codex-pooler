defmodule CodexPooler.Upstreams.Schemas.UpstreamIdentity do
  @moduledoc """
  Persisted upstream account identity.

  The `CodexPooler.Upstreams.Schemas.*` namespace is intentional for upstream
  database structs so runtime callers can distinguish schemas from the operator
  context facade.
  """
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(pending active paused refresh_due refreshing refresh_failed reauth_required deleted disabled errored)
  @onboarding_methods ~w(browser device import invite)
  @plan_family_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()
  @type onboarding_method :: String.t()

  schema "upstream_identities" do
    field :chatgpt_account_id, :string
    field :account_email, :string
    field :account_label, :string
    field :workspace_id, :string
    field :workspace_label, :string
    field :seat_type, :string
    field :onboarding_method, :string
    field :status, :string
    field :plan_family, :string
    field :plan_label, :string
    field :auth_fresh_at, :utc_datetime_usec
    field :auth_verified_at, :utc_datetime_usec
    field :headers_profile_version, :integer
    field :last_successful_refresh_at, :utc_datetime_usec
    field :last_successful_sync_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :created_by_user_id, :binary_id
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :metadata, :map
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :chatgpt_account_id,
      :account_email,
      :account_label,
      :workspace_id,
      :workspace_label,
      :seat_type,
      :onboarding_method,
      :status,
      :plan_family,
      :plan_label,
      :auth_fresh_at,
      :auth_verified_at,
      :headers_profile_version,
      :last_successful_refresh_at,
      :last_successful_sync_at,
      :disabled_at,
      :created_by_user_id,
      :created_at,
      :updated_at,
      :metadata
    ])
    |> update_change(:chatgpt_account_id, &trim_string/1)
    |> update_change(:account_email, &normalize_optional_email/1)
    |> update_change(:account_label, &trim_string/1)
    |> update_change(:workspace_id, &normalize_optional_string/1)
    |> update_change(:workspace_label, &normalize_optional_string/1)
    |> update_change(:seat_type, &normalize_optional_string/1)
    |> update_change(:plan_family, &normalize_optional_token/1)
    |> update_change(:plan_label, &trim_string/1)
    |> validate_required([
      :account_label,
      :onboarding_method,
      :status,
      :headers_profile_version,
      :created_at,
      :updated_at,
      :metadata
    ])
    |> validate_number(:headers_profile_version, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:onboarding_method, @onboarding_methods)
    |> validate_format(:plan_family, @plan_family_format)
    |> unique_constraint(:chatgpt_account_id,
      name: :upstream_identities_chatgpt_legacy_workspace_uq
    )
    |> unique_constraint(:workspace_id,
      name: :upstream_identities_chatgpt_workspace_slot_uq
    )
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec onboarding_methods() :: [onboarding_method()]
  def onboarding_methods, do: @onboarding_methods

  @spec pending_status() :: status()
  def pending_status, do: "pending"

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec paused_status() :: status()
  def paused_status, do: "paused"

  @spec refresh_due_status() :: status()
  def refresh_due_status, do: "refresh_due"

  @spec refreshing_status() :: status()
  def refreshing_status, do: "refreshing"

  @spec refresh_failed_status() :: status()
  def refresh_failed_status, do: "refresh_failed"

  @spec reauth_required_status() :: status()
  def reauth_required_status, do: "reauth_required"

  @spec deleted_status() :: status()
  def deleted_status, do: "deleted"

  @spec disabled_status() :: status()
  def disabled_status, do: "disabled"

  @spec errored_status() :: status()
  def errored_status, do: "errored"

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_optional_token(value) when is_binary(value) do
    case normalize_token(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_token(value), do: value

  defp normalize_optional_email(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_email(value), do: value

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(value), do: value

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
