defmodule CodexPooler.Accounting.RequestReplayEntitlement do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.InstanceSettings.AppSecretCrypto

  @statuses ~w(armed consumed expired revoked)
  @digest_bytes 32

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()
  @type digest_result :: {:ok, binary()} | {:error, atom() | map()}

  schema "request_replay_entitlements" do
    field :request_id, :binary_id
    field :codex_turn_id, :binary_id
    field :eligible_attempt_id, :binary_id
    field :replay_attempt_id, :binary_id
    field :api_key_id, :binary_id
    field :api_key_runtime_epoch, :integer
    field :pool_id, :binary_id
    field :model_id, :binary_id
    field :model_identifier, :string
    field :semantic_turn_digest, :binary
    field :replay_claim_digest, :binary
    field :provisional_binding_digest, :binary
    field :replay_generation, :integer, default: 1
    field :owner_lease_digest, :binary
    field :owner_lease_key_version, :string
    field :predecessor_epoch, :integer
    field :status, :string, default: "armed"
    field :armed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :last_liveness_at, :utc_datetime_usec
    field :abandon_at, :utc_datetime_usec
    field :terminal_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :cleanup_checked_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, __schema__(:fields) -- [:id])
    |> validate_required([
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :api_key_id,
      :api_key_runtime_epoch,
      :pool_id,
      :model_id,
      :model_identifier,
      :semantic_turn_digest,
      :replay_claim_digest,
      :replay_generation,
      :owner_lease_digest,
      :owner_lease_key_version,
      :predecessor_epoch,
      :status,
      :armed_at,
      :expires_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:api_key_runtime_epoch, greater_than_or_equal_to: 0)
    |> validate_number(:replay_generation, equal_to: 1)
    |> validate_number(:predecessor_epoch, greater_than_or_equal_to: 1)
    |> validate_trimmed_present(:model_identifier)
    |> validate_trimmed_present(:owner_lease_key_version)
    |> validate_digest(:semantic_turn_digest, required?: true)
    |> validate_digest(:replay_claim_digest, required?: true)
    |> validate_digest(:provisional_binding_digest, required?: false)
    |> validate_digest(:owner_lease_digest, required?: true)
    |> validate_expiry()
    |> validate_lifecycle_tuple()
    |> unique_constraint(:request_id, name: :request_replay_entitlements_request_id_uq)
    |> foreign_key_constraint(:request_id,
      name: :request_replay_entitlements_request_id_fkey
    )
    |> foreign_key_constraint(:codex_turn_id,
      name: :request_replay_entitlements_codex_turn_request_fkey
    )
    |> foreign_key_constraint(:eligible_attempt_id,
      name: :request_replay_entitlements_eligible_attempt_request_fkey
    )
    |> foreign_key_constraint(:replay_attempt_id,
      name: :request_replay_entitlements_replay_attempt_request_fkey
    )
    |> foreign_key_constraint(:api_key_id,
      name: :request_replay_entitlements_api_key_id_fkey
    )
    |> foreign_key_constraint(:pool_id, name: :request_replay_entitlements_pool_id_fkey)
    |> foreign_key_constraint(:model_id, name: :request_replay_entitlements_model_id_fkey)
    |> check_constraint(:status, name: :request_replay_entitlements_lifecycle_tuple_check)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec owner_lease_digest(String.t()) :: digest_result()
  def owner_lease_digest(owner_lease_uuid) when is_binary(owner_lease_uuid) do
    with :ok <- validate_canonical_uuid(owner_lease_uuid),
         {:ok, key_version} <- configured_key_version() do
      AppSecretCrypto.hmac_digest(
        :erlang.term_to_binary(
          {"codex_pooler.owner_lease_digest", 1, key_version, owner_lease_uuid},
          [:deterministic]
        )
      )
    end
  end

  def owner_lease_digest(_owner_lease_uuid), do: {:error, :invalid_owner_lease_uuid}

  @spec verify_owner_lease_digest(String.t(), String.t(), binary()) :: boolean()
  def verify_owner_lease_digest(owner_lease_uuid, stored_key_version, expected_digest)
      when is_binary(stored_key_version) and is_binary(expected_digest) and
             byte_size(expected_digest) == @digest_bytes do
    with {:ok, configured_key_version} <- configured_key_version(),
         true <- Plug.Crypto.secure_compare(stored_key_version, configured_key_version),
         {:ok, digest} <- owner_lease_digest(owner_lease_uuid) do
      Plug.Crypto.secure_compare(digest, expected_digest)
    else
      _error -> false
    end
  end

  def verify_owner_lease_digest(_owner_lease_uuid, _stored_key_version, _expected_digest),
    do: false

  @spec provisional_binding_digest(binary()) :: digest_result()
  def provisional_binding_digest(raw_token)
      when is_binary(raw_token) and byte_size(raw_token) == @digest_bytes do
    with {:ok, key_version} <- configured_key_version() do
      AppSecretCrypto.hmac_digest(
        :erlang.term_to_binary(
          {"codex_pooler.replay_provisional_binding", 1, key_version, raw_token},
          [:deterministic]
        )
      )
    end
  end

  def provisional_binding_digest(_raw_token), do: {:error, :invalid_provisional_token}

  @spec reserve_receipt_digest(binary(), binary(), pos_integer()) :: digest_result()
  def reserve_receipt_digest(raw_token, receipt, timeout_ms)
      when is_binary(raw_token) and byte_size(raw_token) == @digest_bytes and
             is_binary(receipt) and byte_size(receipt) == @digest_bytes and
             is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, key_version} <- configured_key_version() do
      AppSecretCrypto.hmac_digest(
        :erlang.term_to_binary(
          {"codex_pooler.replay_reserve_receipt", 1, key_version, raw_token, receipt, timeout_ms},
          [:deterministic]
        )
      )
    end
  end

  def reserve_receipt_digest(_raw_token, _receipt, _timeout_ms),
    do: {:error, :invalid_reserve_receipt}

  @spec verify_provisional_binding(binary(), String.t(), binary()) :: boolean()
  def verify_provisional_binding(raw_token, stored_key_version, expected_digest)
      when is_binary(stored_key_version) and is_binary(expected_digest) and
             byte_size(expected_digest) == @digest_bytes do
    with {:ok, configured_key_version} <- configured_key_version(),
         true <- Plug.Crypto.secure_compare(stored_key_version, configured_key_version),
         {:ok, digest} <- provisional_binding_digest(raw_token) do
      Plug.Crypto.secure_compare(digest, expected_digest)
    else
      _error -> false
    end
  end

  def verify_provisional_binding(_raw_token, _stored_key_version, _expected_digest), do: false

  defp validate_digest(changeset, field, opts) do
    required? = Keyword.fetch!(opts, :required?)

    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_binary(value) and byte_size(value) == @digest_bytes -> []
        is_nil(value) and not required? -> []
        true -> [{field, "must be exactly 32 bytes"}]
      end
    end)
  end

  defp validate_trimmed_present(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) != "" do
        []
      else
        [{field, "must contain non-whitespace characters"}]
      end
    end)
  end

  defp validate_expiry(changeset) do
    armed_at = get_field(changeset, :armed_at)
    expires_at = get_field(changeset, :expires_at)

    if match?(%DateTime{}, armed_at) and match?(%DateTime{}, expires_at) and
         DateTime.compare(expires_at, armed_at) != :gt do
      add_error(changeset, :expires_at, "must be after armed_at")
    else
      changeset
    end
  end

  defp validate_lifecycle_tuple(changeset) do
    if lifecycle_tuple_valid?(get_field(changeset, :status), changeset) do
      changeset
    else
      add_error(changeset, :status, "has an invalid replay lifecycle tuple")
    end
  end

  defp lifecycle_tuple_valid?("armed", changeset) do
    all_nil?(changeset, [
      :replay_attempt_id,
      :provisional_binding_digest,
      :consumed_at,
      :started_at,
      :last_liveness_at,
      :abandon_at,
      :terminal_at,
      :closed_at
    ])
  end

  defp lifecycle_tuple_valid?("consumed", changeset) do
    consumed_at = get_field(changeset, :consumed_at)
    started_at = get_field(changeset, :started_at)
    last_liveness_at = get_field(changeset, :last_liveness_at)
    abandon_at = get_field(changeset, :abandon_at)
    closed_at = get_field(changeset, :closed_at)

    required_present?(changeset, [
      :replay_attempt_id,
      :provisional_binding_digest,
      :consumed_at,
      :abandon_at
    ]) and is_nil(get_field(changeset, :terminal_at)) and
      paired_times_valid?(consumed_at, started_at, last_liveness_at, abandon_at) and
      after_if_present?(closed_at, last_liveness_at || started_at || consumed_at)
  end

  defp lifecycle_tuple_valid?(status, changeset) when status in ["expired", "revoked"] do
    terminal_at = get_field(changeset, :terminal_at)
    closed_at = get_field(changeset, :closed_at)
    armed_at = get_field(changeset, :armed_at)

    all_nil?(changeset, [
      :replay_attempt_id,
      :provisional_binding_digest,
      :consumed_at,
      :started_at,
      :last_liveness_at,
      :abandon_at
    ]) and match?(%DateTime{}, terminal_at) and match?(%DateTime{}, closed_at) and
      terminal_time_valid?(status, terminal_at, armed_at, get_field(changeset, :expires_at)) and
      after_if_present?(closed_at, terminal_at)
  end

  defp lifecycle_tuple_valid?(_status, _changeset), do: false

  defp terminal_time_valid?("expired", terminal_at, _armed_at, expires_at),
    do: not_before?(terminal_at, expires_at)

  defp terminal_time_valid?("revoked", terminal_at, armed_at, _expires_at),
    do: not_before?(terminal_at, armed_at)

  defp paired_times_valid?(consumed_at, nil, nil, abandon_at),
    do: before?(consumed_at, abandon_at)

  defp paired_times_valid?(consumed_at, started_at, last_liveness_at, abandon_at)
       when not is_nil(started_at) and not is_nil(last_liveness_at) do
    not_before?(started_at, consumed_at) and not_before?(last_liveness_at, started_at) and
      before?(last_liveness_at, abandon_at)
  end

  defp paired_times_valid?(_consumed_at, _started_at, _last_liveness_at, _abandon_at), do: false

  defp all_nil?(changeset, fields), do: Enum.all?(fields, &is_nil(get_field(changeset, &1)))

  defp required_present?(changeset, fields),
    do: Enum.all?(fields, &(not is_nil(get_field(changeset, &1))))

  defp before?(%DateTime{} = earlier, %DateTime{} = later),
    do: DateTime.compare(earlier, later) == :lt

  defp before?(_earlier, _later), do: false

  defp not_before?(%DateTime{} = later, %DateTime{} = earlier),
    do: DateTime.compare(later, earlier) != :lt

  defp not_before?(_later, _earlier), do: false

  defp after_if_present?(nil, _state_at), do: true
  defp after_if_present?(%DateTime{} = later, %DateTime{} = earlier), do: before?(earlier, later)
  defp after_if_present?(_later, _earlier), do: false

  defp validate_canonical_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} when byte_size(value) == 36 -> :ok
      _invalid -> {:error, :invalid_owner_lease_uuid}
    end
  end

  defp configured_key_version do
    case AppSecretCrypto.key_version() do
      value when is_binary(value) and value != "" ->
        if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_key_version}

      _invalid ->
        {:error, :invalid_key_version}
    end
  end
end
