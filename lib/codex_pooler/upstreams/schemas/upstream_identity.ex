defmodule CodexPooler.Upstreams.Schemas.UpstreamIdentity do
  @moduledoc """
  Persisted upstream account identity.

  The `CodexPooler.Upstreams.Schemas.*` namespace is intentional for upstream
  database structs so runtime callers can distinguish schemas from the operator
  context facade.
  """
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @statuses IdentityStatus.statuses()
  @onboarding_methods ~w(browser device import invite)
  @saved_reset_auto_redeem_trigger_modes ~w(blocked threshold)
  @plan_family_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @codex_chatgpt_oauth "codex_chatgpt_oauth"
  @synthetic_account_id_prefixes ~w(email_ local_)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()
  @type onboarding_method :: String.t()

  schema "upstream_identities" do
    field :chatgpt_account_id, :string
    field :chatgpt_user_id, :string
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
    field :credential_provenance, :string
    field :last_successful_refresh_at, :utc_datetime_usec
    field :last_successful_sync_at, :utc_datetime_usec
    field :allow_provider_credits, :boolean, default: true
    field :usage_cap_percent, :integer
    field :saved_reset_auto_redeem_enabled, :boolean, default: false
    field :saved_reset_auto_redeem_min_blocked_minutes, :integer, default: 60
    field :saved_reset_auto_redeem_keep_credits, :integer, default: 0
    field :saved_reset_auto_redeem_trigger_mode, :string, default: "blocked"
    field :saved_reset_auto_redeem_quota_threshold_percent, :integer, default: 95
    field :saved_reset_first_seen_ledger, :map, default: %{"version" => 1, "entries" => []}

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
      :chatgpt_user_id,
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
      :saved_reset_auto_redeem_enabled,
      :saved_reset_auto_redeem_min_blocked_minutes,
      :saved_reset_auto_redeem_keep_credits,
      :saved_reset_auto_redeem_trigger_mode,
      :saved_reset_auto_redeem_quota_threshold_percent,
      :disabled_at,
      :created_by_user_id,
      :created_at,
      :updated_at,
      :metadata
    ])
    |> update_change(:chatgpt_account_id, &trim_string/1)
    |> update_change(:chatgpt_user_id, &normalize_optional_string/1)
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
    |> validate_number(:saved_reset_auto_redeem_min_blocked_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:saved_reset_auto_redeem_keep_credits, greater_than_or_equal_to: 0)
    |> validate_inclusion(
      :saved_reset_auto_redeem_trigger_mode,
      @saved_reset_auto_redeem_trigger_modes
    )
    |> validate_number(:saved_reset_auto_redeem_quota_threshold_percent,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:onboarding_method, @onboarding_methods)
    |> validate_format(:plan_family, @plan_family_format)
    |> unique_constraint(:chatgpt_account_id,
      name: :upstream_identities_chatgpt_legacy_workspace_uq
    )
    |> unique_constraint(:workspace_id,
      name: :upstream_identities_chatgpt_workspace_slot_uq
    )
    |> unique_constraint(:chatgpt_user_id,
      name: :upstream_identities_chatgpt_user_legacy_workspace_uq
    )
    |> unique_constraint(:chatgpt_user_id,
      name: :upstream_identities_chatgpt_user_workspace_slot_uq
    )
  end

  @doc """
  Changes only the identity-wide provider credits policy.

  The control is required even when unchanged. Ownership and provider metadata
  are never accepted, and generic identity changesets cannot overwrite this policy.
  """
  @spec provider_credits_policy_changeset(t(), attrs()) :: Ecto.Changeset.t()
  def provider_credits_policy_changeset(%__MODULE__{} = identity, attrs) when is_map(attrs) do
    changeset = change(identity)

    case attrs do
      %{allow_provider_credits: value} when map_size(attrs) == 1 ->
        put_provider_credits_policy(changeset, value)

      %{"allow_provider_credits" => value} when map_size(attrs) == 1 ->
        put_provider_credits_policy(changeset, value)

      attrs when map_size(attrs) == 0 ->
        add_error(changeset, :allow_provider_credits, "is required")

      _attrs ->
        add_error(changeset, :allow_provider_credits, "only the provider credits control may be changed")
    end
  end

  defp put_provider_credits_policy(changeset, value) when value in [true, "true", "1"],
    do: put_change(changeset, :allow_provider_credits, true)

  defp put_provider_credits_policy(changeset, value) when value in [false, "false", "0"],
    do: put_change(changeset, :allow_provider_credits, false)

  defp put_provider_credits_policy(changeset, _value),
    do: add_error(changeset, :allow_provider_credits, "must be a boolean")

  @doc """
  Changes only the identity-wide usage cap.

  The cap is a whole percentage from 1 to 99 of the account's long window
  (weekly, or 30-day on a plan without a weekly window), or
  `nil` (also given as a blank string) for no cap. The key is required even
  when unchanged; any other key is refused, and generic identity changesets
  cannot overwrite the cap.
  """
  @spec usage_cap_policy_changeset(t(), attrs()) :: Ecto.Changeset.t()
  def usage_cap_policy_changeset(%__MODULE__{} = identity, attrs) when is_map(attrs) do
    changeset = change(identity)

    case attrs do
      %{usage_cap_percent: value} when map_size(attrs) == 1 ->
        put_usage_cap_policy(changeset, value)

      %{"usage_cap_percent" => value} when map_size(attrs) == 1 ->
        put_usage_cap_policy(changeset, value)

      attrs when map_size(attrs) == 0 ->
        add_error(changeset, :usage_cap_percent, "is required")

      _attrs ->
        add_error(changeset, :usage_cap_percent, "only the usage cap may be changed")
    end
  end

  defp put_usage_cap_policy(changeset, nil), do: put_change(changeset, :usage_cap_percent, nil)

  defp put_usage_cap_policy(changeset, value) when is_integer(value) and value >= 1 and value <= 99,
    do: put_change(changeset, :usage_cap_percent, value)

  defp put_usage_cap_policy(changeset, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        put_usage_cap_policy(changeset, nil)

      trimmed ->
        case Integer.parse(trimmed) do
          {integer, ""} -> put_usage_cap_policy(changeset, integer)
          _invalid -> usage_cap_range_error(changeset)
        end
    end
  end

  defp put_usage_cap_policy(changeset, _value), do: usage_cap_range_error(changeset)

  defp usage_cap_range_error(changeset),
    do: add_error(changeset, :usage_cap_percent, "must be a whole number from 1 to 99, or blank for no cap")

  @doc """
  The provider-routable `chatgpt-account-id` scope for a stored account id, or `nil`.

  This is the read-side counterpart of the `:chatgpt_account_id` trim above, and
  it lives here so every caller that has to decide whether an account id can be
  put on the wire asks the same question in the same place.

  The value is provider-supplied, never minted by us: `Upstreams.Auth.CodexAuth`
  reads it from the `chatgpt_account_id` id-token claim, and
  `Upstreams.Auth.CodexAuthJson` reads `account_id` out of an imported Codex
  `auth.json`. Some credentials carry a synthetic placeholder there instead of a
  real account identifier — an `email_`-prefixed value derived from the signed-in
  address, or a `local_`-prefixed value minted for a local login. Those are not
  identifiers the provider can resolve, so sending one as `chatgpt-account-id`
  scopes the request to an account the provider does not know instead of letting
  the bearer token speak for itself. They are therefore not a scope at all, and
  this returns `nil` for them.

  The prefix test is deliberately case-sensitive: it matches the exact lowercase
  spellings the provider mints, and anything else stays routable rather than
  being guessed at.

  Returns the trimmed binary when the id is routable, and `nil` for a non-binary
  value, a blank value, or a synthetic placeholder. What `nil` means is the
  caller's decision — omitting the header and substituting an empty scope are
  both legitimate, and neither belongs in here.
  """
  @spec account_scope(term()) :: String.t() | nil
  def account_scope(account_id) when is_binary(account_id) do
    trimmed = String.trim(account_id)

    if trimmed == "" or String.starts_with?(trimmed, @synthetic_account_id_prefixes) do
      nil
    else
      trimmed
    end
  end

  def account_scope(_account_id), do: nil

  @spec statuses() :: [status()]
  defdelegate statuses(), to: IdentityStatus

  @spec authenticated_codex_chatgpt?(t()) :: boolean()
  def authenticated_codex_chatgpt?(%__MODULE__{
        credential_provenance: @codex_chatgpt_oauth
      }),
      do: true

  def authenticated_codex_chatgpt?(%__MODULE__{}), do: false

  @spec put_credential_provenance(Ecto.Changeset.t(), :codex_chatgpt | :unclassified) ::
          Ecto.Changeset.t()
  def put_credential_provenance(changeset, :codex_chatgpt),
    do: put_change(changeset, :credential_provenance, @codex_chatgpt_oauth)

  def put_credential_provenance(changeset, :unclassified),
    do: put_change(changeset, :credential_provenance, nil)

  @spec onboarding_methods() :: [onboarding_method()]
  def onboarding_methods, do: @onboarding_methods

  @spec pending_status() :: status()
  defdelegate pending_status(), to: IdentityStatus

  @spec active_status() :: status()
  defdelegate active_status(), to: IdentityStatus

  @spec paused_status() :: status()
  defdelegate paused_status(), to: IdentityStatus

  @spec refresh_due_status() :: status()
  defdelegate refresh_due_status(), to: IdentityStatus

  @spec refreshing_status() :: status()
  defdelegate refreshing_status(), to: IdentityStatus

  @spec refresh_failed_status() :: status()
  defdelegate refresh_failed_status(), to: IdentityStatus

  @spec reauth_required_status() :: status()
  defdelegate reauth_required_status(), to: IdentityStatus

  @spec deleted_status() :: status()
  defdelegate deleted_status(), to: IdentityStatus

  @spec disabled_status() :: status()
  defdelegate disabled_status(), to: IdentityStatus

  @spec errored_status() :: status()
  defdelegate errored_status(), to: IdentityStatus

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
