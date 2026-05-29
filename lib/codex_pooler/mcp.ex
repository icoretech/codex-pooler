defmodule CodexPooler.MCP do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP.AuditLog
  alias CodexPooler.MCP.{Material, OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Repo

  @type mcp_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec create_operator_token(User.t(), map()) ::
          {:ok, %{key: OperatorMCPKey.t(), raw_token: String.t()}} | {:error, Ecto.Changeset.t()}
  def create_operator_token(%User{id: operator_id} = operator, attrs) when is_map(attrs) do
    {key_prefix, raw_token, key_hash} = Material.generate()

    attrs = %{
      operator_id: operator_id,
      label: Map.get(attrs, :label) || Map.get(attrs, "label"),
      key_prefix: key_prefix,
      key_hash: key_hash
    }

    %OperatorMCPKey{}
    |> OperatorMCPKey.changeset(attrs)
    |> Repo.insert()
    |> AuditLog.audit_operator_token_create(operator)
    |> case do
      {:ok, key} -> {:ok, %{key: key, raw_token: raw_token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec list_operator_tokens(User.t()) :: {:ok, [OperatorMCPKey.t()]} | {:error, mcp_error()}
  def list_operator_tokens(%User{id: operator_id}) do
    keys =
      Repo.all(
        from key in OperatorMCPKey,
          where: key.operator_id == ^operator_id,
          order_by: [desc: key.inserted_at, desc: key.id]
      )

    {:ok, keys}
  end

  def list_operator_tokens(_user), do: {:error, error(:invalid_operator, "operator is required")}

  @spec count_operator_tokens() :: non_neg_integer()
  def count_operator_tokens do
    Repo.aggregate(OperatorMCPKey, :count, :id)
  end

  @spec get_operator_token(User.t(), Ecto.UUID.t()) ::
          {:ok, OperatorMCPKey.t()} | {:error, mcp_error()}
  def get_operator_token(%User{id: operator_id}, key_id) when is_binary(key_id) do
    case Repo.get_by(OperatorMCPKey, id: key_id, operator_id: operator_id) do
      %OperatorMCPKey{} = key -> {:ok, key}
      nil -> {:error, error(:mcp_token_missing, "MCP token was not found")}
    end
  end

  def get_operator_token(_user, _key_id),
    do: {:error, error(:invalid_operator, "operator is required")}

  @spec update_operator_token(User.t(), Ecto.UUID.t(), map()) ::
          {:ok, OperatorMCPKey.t()} | {:error, Ecto.Changeset.t() | mcp_error()}
  def update_operator_token(%User{} = user, key_id, attrs) when is_map(attrs) do
    with {:ok, key} <- get_operator_token(user, key_id) do
      key
      |> OperatorMCPKey.label_changeset(attrs)
      |> Repo.update()
      |> AuditLog.audit_operator_token_update(user, key)
    end
  end

  def update_operator_token(_user, _key_id, _attrs),
    do: {:error, error(:invalid_operator, "operator is required")}

  @spec delete_operator_token(User.t(), Ecto.UUID.t()) ::
          {:ok, OperatorMCPKey.t()} | {:error, Ecto.Changeset.t() | mcp_error()}
  def delete_operator_token(%User{} = user, key_id) do
    with {:ok, key} <- get_operator_token(user, key_id) do
      Repo.delete(key)
      |> AuditLog.audit_operator_token_delete(user)
    end
  end

  def delete_operator_token(_user, _key_id),
    do: {:error, error(:invalid_operator, "operator is required")}

  @spec set_operator_mcp_enabled(User.t(), boolean()) ::
          {:ok, OperatorMCPSettings.t()} | {:error, Ecto.Changeset.t() | mcp_error()}
  def set_operator_mcp_enabled(%User{id: operator_id} = operator, enabled)
      when is_boolean(enabled) do
    attrs = %{operator_id: operator_id, enabled: enabled}

    %OperatorMCPSettings{operator_id: operator_id}
    |> OperatorMCPSettings.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [enabled: enabled, updated_at: DateTime.utc_now()]],
      conflict_target: :operator_id,
      returning: true
    )
    |> AuditLog.audit_operator_mcp_setting(operator, enabled)
  end

  def set_operator_mcp_enabled(_user, _enabled),
    do: {:error, error(:invalid_operator, "operator is required")}

  @spec operator_mcp_enabled?(User.t()) :: boolean()
  def operator_mcp_enabled?(%User{id: operator_id}) do
    match?(%OperatorMCPSettings{enabled: true}, Repo.get(OperatorMCPSettings, operator_id))
  end

  def operator_mcp_enabled?(_user), do: false

  @spec authenticate_token(term()) :: {:ok, map()} | {:error, mcp_error()}
  def authenticate_token(raw_token) when is_binary(raw_token) do
    with :ok <- ensure_global_enabled(),
         {:ok, key_prefix, secret} <- Material.split(raw_token),
         %OperatorMCPKey{} = key <- Repo.get_by(OperatorMCPKey, key_prefix: key_prefix),
         :ok <- Material.verify(key.key_hash, secret),
         %User{} = operator <- Repo.get(User, key.operator_id),
         :ok <- ensure_operator_usable(operator),
         :ok <- ensure_account_enabled(operator) do
      operator = Map.put(operator, :password, nil)
      {:ok, %{operator: operator, scope: Scope.for_user(operator), key: key, key_id: key.id}}
    else
      nil -> {:error, error(:mcp_token_missing, "MCP token is required")}
      {:error, :empty_mcp_token} -> {:error, error(:mcp_token_missing, "MCP token is required")}
      {:error, :invalid_mcp_token} -> {:error, error(:mcp_token_missing, "MCP token is required")}
      :invalid_secret -> {:error, error(:mcp_token_missing, "MCP token is required")}
      {:error, _reason} = error -> error
    end
  end

  def authenticate_token(_raw_token),
    do: {:error, error(:mcp_token_missing, "MCP token is required")}

  @spec hash_mcp_token_secret(binary()) :: binary()
  def hash_mcp_token_secret(secret), do: Material.hash_secret(secret)

  defp ensure_global_enabled do
    if InstanceSettings.current().mcp.enabled do
      :ok
    else
      {:error, error(:mcp_service_disabled, "MCP service is disabled")}
    end
  end

  defp ensure_operator_usable(%User{deleted_at: %DateTime{}}),
    do: {:error, error(:mcp_operator_deleted, "MCP operator is deleted")}

  defp ensure_operator_usable(%User{status: status}) when status != "active",
    do: {:error, error(:mcp_operator_disabled, "MCP operator is disabled")}

  defp ensure_operator_usable(%User{password_change_required: true}),
    do:
      {:error,
       error(
         :mcp_operator_password_change_required,
         "MCP operator must complete password change"
       )}

  defp ensure_operator_usable(%User{}), do: :ok

  defp ensure_account_enabled(%User{} = operator) do
    if operator_mcp_enabled?(operator) do
      :ok
    else
      {:error, error(:mcp_account_disabled, "MCP is disabled for this operator")}
    end
  end

  defp error(code, message), do: %{code: code, message: message}
end
