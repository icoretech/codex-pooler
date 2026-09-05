defmodule CodexPooler.Upstreams.PreparedAccount do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Auth.AccessTokenExpiry

  @reserved_attr_keys ~w(credential_policy prepared_account __prepared_account__)a
  @reserved_string_keys Enum.map(@reserved_attr_keys, &Atom.to_string/1)

  @type policy :: :reject_expired | :bundle_recovery
  @type t :: %__MODULE__{
          scope_user_id: Ecto.UUID.t(),
          pool_id: Ecto.UUID.t(),
          attrs: map(),
          expiry: AccessTokenExpiry.resolution(),
          policy: policy()
        }

  @enforce_keys [:scope_user_id, :pool_id, :attrs, :expiry, :policy]
  defstruct [:scope_user_id, :pool_id, :attrs, :expiry, :policy]

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
         policy: :reject_expired
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
  defp invalid_request, do: %{code: :invalid_request, message: "token linking request is invalid"}
end

defimpl Inspect, for: CodexPooler.Upstreams.PreparedAccount do
  import Inspect.Algebra

  def inspect(_prepared, opts), do: concat(["#PreparedAccount<", to_doc(:redacted, opts), ">"])
end
