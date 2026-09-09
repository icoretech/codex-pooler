defmodule CodexPooler.Upstreams.PreparedAccount do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Auth.AccessTokenExpiry
  alias CodexPooler.Upstreams.Lifecycle.{CredentialFencing, IdentityLifecycle, IdentitySlotLock}
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @reserved_attr_keys ~w(credential_policy prepared_account __prepared_account__)a
  @reserved_string_keys Enum.map(@reserved_attr_keys, &Atom.to_string/1)
  @import_witness_purpose "codex_pooler.upstreams.import_witness"
  @import_witness_version 1
  @import_binding_bytes 32
  @import_witness_key_domain "codex_pooler.upstreams.import_witness.hmac_key"

  @type policy :: :reject_expired | :bundle_recovery
  @type import_prepare_error ::
          %{code: atom(), message: String.t()} | IdentityLifecycle.identity_conflict()
  @type selection_key :: IdentitySlotLock.normalized_identity()
  @type persisted_identity_evidence :: %{
          required(:identity_id) => Ecto.UUID.t(),
          required(:chatgpt_account_id) => String.t() | nil,
          required(:workspace_id) => String.t() | nil,
          required(:chatgpt_user_id) => String.t() | nil,
          required(:account_email) => String.t() | nil,
          required(:credential_epoch) => pos_integer(),
          required(:status) => String.t()
        }
  @type import_witness :: %{
          required(:incoming) => selection_key(),
          required(:persisted) => :absent | persisted_identity_evidence()
        }
  @type t :: %__MODULE__{
          scope_user_id: Ecto.UUID.t(),
          pool_id: Ecto.UUID.t(),
          attrs: map(),
          expiry: AccessTokenExpiry.resolution(),
          policy: policy(),
          import_witness: import_witness() | nil,
          import_binding: binary() | nil
        }

  @enforce_keys [
    :scope_user_id,
    :pool_id,
    :attrs,
    :expiry,
    :policy,
    :import_witness,
    :import_binding
  ]
  defstruct [:scope_user_id, :pool_id, :attrs, :expiry, :policy, :import_witness, :import_binding]

  @spec prepare(Scope.t(), Pool.t(), map(), keyword()) ::
          {:ok, t()} | {:error, %{code: atom(), message: String.t()}}
  def prepare(%Scope{} = scope, %Pool{} = pool, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with :ok <- reject_reserved(attrs, opts),
         :ok <- require_pool_operate(scope, pool) do
      normalized = normalize(attrs, opts)

      {:ok,
       %__MODULE__{
         scope_user_id: scope.user.id,
         pool_id: pool.id,
         attrs: normalized,
         expiry: AccessTokenExpiry.resolve(normalized),
         policy: :reject_expired,
         import_witness: nil,
         import_binding: nil
       }}
    end
  end

  def prepare(_scope, _pool, _attrs, _opts), do: {:error, invalid_request()}

  @spec prepare_bundle(Scope.t(), Pool.t(), map(), keyword()) ::
          {:ok, t()} | {:error, %{code: atom(), message: String.t()}}
  def prepare_bundle(%Scope{} = scope, %Pool{} = pool, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with {:ok, prepared} <- prepare(scope, pool, attrs, opts),
         true <- present_string?(prepared.attrs.refresh_token) do
      {:ok, %{prepared | policy: :bundle_recovery}}
    else
      false -> {:error, invalid_request()}
      {:error, _reason} = error -> error
    end
  end

  def prepare_bundle(_scope, _pool, _attrs, _opts), do: {:error, invalid_request()}

  @spec prepare_import(Scope.t(), Pool.t(), map(), keyword()) ::
          {:ok, t()} | {:error, import_prepare_error()}
  def prepare_import(%Scope{} = scope, %Pool{} = pool, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with {:ok, prepared} <- prepare(scope, pool, attrs, opts),
         {:ok, selected_identity} <- IdentityLifecycle.select_upsert_identity(prepared.attrs) do
      attach_import_witness(prepared, selected_identity)
    end
  end

  def prepare_import(_scope, _pool, _attrs, _opts), do: {:error, invalid_request()}

  @spec prepare_import_bundle(Scope.t(), Pool.t(), map(), keyword()) ::
          {:ok, t()} | {:error, import_prepare_error()}
  def prepare_import_bundle(%Scope{} = scope, %Pool{} = pool, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with {:ok, prepared} <- prepare_bundle(scope, pool, attrs, opts),
         {:ok, selected_identity} <- IdentityLifecycle.select_upsert_identity(prepared.attrs) do
      attach_import_witness(prepared, selected_identity)
    end
  end

  def prepare_import_bundle(_scope, _pool, _attrs, _opts), do: {:error, invalid_request()}

  defp attach_import_witness(%__MODULE__{} = prepared, selected_identity) do
    with {:ok, persisted} <- persisted_evidence(selected_identity) do
      witness = %{
        incoming: IdentitySlotLock.normalize(prepared.attrs),
        persisted: persisted
      }

      with {:ok, binding} <- import_binding(prepared, witness) do
        {:ok, %{prepared | import_witness: witness, import_binding: binding}}
      end
    end
  end

  @spec validate(t(), Scope.t(), Pool.t()) ::
          {:ok, t()} | {:error, %{code: atom(), message: String.t()}}
  def validate(
        %__MODULE__{} = prepared,
        %Scope{} = scope,
        %Pool{} = pool
      ) do
    expected_expiry = AccessTokenExpiry.resolve(prepared.attrs)

    with true <- prepared.scope_user_id == scope.user.id,
         true <- prepared.pool_id == pool.id,
         true <- prepared.policy in [:reject_expired, :bundle_recovery],
         true <- prepared.expiry == expected_expiry,
         true <- valid_normalized_attrs?(prepared.attrs),
         true <- valid_import_witness?(prepared),
         true <-
           prepared.policy != :bundle_recovery or present_string?(prepared.attrs.refresh_token),
         :ok <- require_pool_operate(scope, pool) do
      {:ok, prepared}
    else
      _invalid -> {:error, invalid_request()}
    end
  end

  def validate(_prepared, _scope, _pool), do: {:error, invalid_request()}

  @spec evaluate(t(), DateTime.t()) :: :ok | {:error, %{code: atom(), message: String.t()}}
  def evaluate(%__MODULE__{} = prepared, %DateTime{} = evaluated_at) do
    case AccessTokenExpiry.evaluate(prepared.expiry, evaluated_at) do
      %{state: :expired} when prepared.policy == :reject_expired ->
        {:error, %{code: :access_token_expired, message: "access token is expired"}}

      _usable ->
        :ok
    end
  end

  @spec normalize(map(), keyword()) :: map()
  def normalize(attrs, opts) do
    %{
      chatgpt_account_id: value(attrs, :chatgpt_account_id),
      chatgpt_user_id: value(attrs, :chatgpt_user_id),
      account_email: value(attrs, :account_email),
      account_label: value(attrs, :account_label),
      workspace_id: value(attrs, :workspace_id),
      workspace_label: value(attrs, :workspace_label),
      seat_type: value(attrs, :seat_type),
      plan_label: value(attrs, :plan_label),
      token: value(attrs, :token) || value(attrs, :access_token),
      access_token: value(attrs, :token) || value(attrs, :access_token),
      refresh_token: value(attrs, :refresh_token),
      access_token_expires_at: value(attrs, :access_token_expires_at),
      expires_in: value(attrs, :expires_in),
      received_at: value(attrs, :received_at),
      identity_metadata:
        value(attrs, :import_metadata) || value(attrs, :identity_metadata) || %{},
      credential_provenance: credential_provenance(opts),
      onboarding_method:
        Keyword.get(opts, :onboarding_method, value(attrs, :onboarding_method) || "import"),
      actor_metadata_key: Keyword.get(opts, :actor_metadata_key, "imported_by_user_id"),
      token_refresh_trigger_kind:
        Keyword.get(opts, :token_refresh_trigger_kind, "auth_json_import"),
      target_identity_id: Keyword.get(opts, :target_identity_id)
    }
  end

  defp reject_reserved(attrs, opts) do
    reserved_attr? =
      Enum.any?(@reserved_attr_keys, &Map.has_key?(attrs, &1)) or
        Enum.any?(@reserved_string_keys, &Map.has_key?(attrs, &1))

    reserved_opt? =
      Keyword.has_key?(opts, :credential_policy) or Keyword.has_key?(opts, :prepared_account)

    if reserved_attr? or reserved_opt?, do: {:error, invalid_request()}, else: :ok
  end

  defp require_pool_operate(%Scope{} = scope, %Pool{} = pool) do
    case Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool.id) do
      {:ok, _decision} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_normalized_attrs?(attrs) do
    is_map(attrs) and present_string?(attrs.token) and present_string?(attrs.account_label) and
      (present_string?(attrs.chatgpt_account_id) or present_string?(attrs.account_email))
  end

  defp persisted_evidence(nil), do: {:ok, :absent}

  defp persisted_evidence(%UpstreamIdentity{} = identity) do
    with {:ok, credential_epoch} <- CredentialFencing.validate_current_credential_epoch(identity),
         true <- is_binary(identity.id),
         true <- is_binary(identity.status) do
      normalized = IdentitySlotLock.normalize(Map.from_struct(identity))

      {:ok,
       %{
         identity_id: identity.id,
         chatgpt_account_id: normalized.chatgpt_account_id,
         workspace_id: normalized.workspace_id,
         chatgpt_user_id: normalized.chatgpt_user_id,
         account_email: normalized.account_email,
         credential_epoch: credential_epoch,
         status: identity.status
       }}
    else
      false -> {:error, invalid_request()}
      {:error, _reason} = error -> error
    end
  end

  defp valid_import_witness?(%__MODULE__{import_witness: nil, import_binding: nil}), do: true

  defp valid_import_witness?(%__MODULE__{} = prepared) do
    case prepared.import_witness do
      %{incoming: incoming, persisted: persisted} when is_map(incoming) ->
        incoming == IdentitySlotLock.normalize(prepared.attrs) and
          valid_persisted_evidence?(persisted) and
          is_binary(prepared.import_binding) and
          byte_size(prepared.import_binding) == @import_binding_bytes and
          valid_import_binding?(
            import_binding_payload(prepared, prepared.import_witness),
            prepared.import_binding
          )

      _invalid ->
        false
    end
  end

  defp valid_persisted_evidence?(:absent), do: true

  defp valid_persisted_evidence?(%{
         identity_id: identity_id,
         chatgpt_account_id: chatgpt_account_id,
         workspace_id: workspace_id,
         chatgpt_user_id: chatgpt_user_id,
         account_email: account_email,
         credential_epoch: credential_epoch,
         status: status
       }) do
    is_binary(identity_id) and nullable_string?(chatgpt_account_id) and
      nullable_string?(workspace_id) and
      nullable_string?(chatgpt_user_id) and nullable_string?(account_email) and
      is_integer(credential_epoch) and credential_epoch > 0 and is_binary(status)
  end

  defp valid_persisted_evidence?(_persisted), do: false

  defp import_binding(%__MODULE__{} = prepared, import_witness) do
    with {:ok, key} <- import_witness_hmac_key() do
      {:ok, :crypto.mac(:hmac, :sha256, key, import_binding_payload(prepared, import_witness))}
    end
  end

  defp import_binding_payload(%__MODULE__{} = prepared, import_witness) do
    {@import_witness_purpose, @import_witness_version, prepared.scope_user_id, prepared.pool_id,
     prepared.attrs, prepared.expiry, prepared.policy, import_witness.incoming,
     import_witness.persisted}
    |> :erlang.term_to_binary([:deterministic])
  end

  defp valid_import_binding?(payload, binding) do
    case import_witness_hmac_key() do
      {:ok, key} ->
        digest = :crypto.mac(:hmac, :sha256, key, payload)
        Plug.Crypto.secure_compare(digest, binding)

      {:error, _reason} ->
        false
    end
  end

  defp import_witness_hmac_key do
    case Application.fetch_env(:codex_pooler, CodexPoolerWeb.Endpoint) do
      {:ok, config} when is_list(config) ->
        case Keyword.fetch(config, :secret_key_base) do
          {:ok, secret_key_base} when is_binary(secret_key_base) and secret_key_base != "" ->
            {:ok, :crypto.hash(:sha256, secret_key_base <> <<0>> <> @import_witness_key_domain)}

          _invalid ->
            {:error, invalid_request()}
        end

      _missing ->
        {:error, invalid_request()}
    end
  end

  defp credential_provenance(opts) do
    if Keyword.get(opts, :credential_provenance) == :codex_chatgpt,
      do: :codex_chatgpt,
      else: :unclassified
  end

  defp value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
  defp invalid_request, do: %{code: :invalid_request, message: "token linking request is invalid"}
end

defimpl Inspect, for: CodexPooler.Upstreams.PreparedAccount do
  import Inspect.Algebra

  def inspect(_prepared, opts), do: concat(["#PreparedAccount<", to_doc(:redacted, opts), ">"])
end
