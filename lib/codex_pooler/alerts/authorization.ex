defmodule CodexPooler.Alerts.Authorization do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec list_manageable_pools(term()) ::
          {:ok, [CodexPooler.Pools.Pool.t()]} | {:error, access_error()}
  def list_manageable_pools(%Scope{} = scope), do: Pools.list_pools(scope)

  def list_manageable_pools(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec authorized_pool_filter(term(), String.t() | nil) ::
          {:ok, [Ecto.UUID.t()]} | {:error, access_error()}
  def authorized_pool_filter(%Scope{} = scope, nil) do
    case list_manageable_pools(scope) do
      {:ok, pools} -> {:ok, Enum.map(pools, & &1.id)}
      {:error, _reason} = error -> error
    end
  end

  def authorized_pool_filter(%Scope{} = scope, pool_id) when is_binary(pool_id) do
    with {:ok, _decision} <- authorize_pool_operation(scope, pool_id), do: {:ok, [pool_id]}
  end

  def authorized_pool_filter(_scope, _pool_id),
    do: {:error, access_error(:invalid_request, "pool id must be a string")}

  @spec authorize_pool_operation(term(), String.t()) :: {:ok, term()} | {:error, access_error()}
  def authorize_pool_operation(scope, pool_id) when is_binary(pool_id) do
    Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool_id)
  end

  def authorize_pool_operation(_scope, _pool_id),
    do: {:error, access_error(:invalid_request, "pool id must be a string")}

  @spec scope_user_id(term()) :: {:ok, Ecto.UUID.t()} | {:error, access_error()}
  def scope_user_id(%Scope{user: %{id: user_id}}) when is_binary(user_id), do: {:ok, user_id}

  def scope_user_id(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec access_error(atom(), String.t()) :: access_error()
  def access_error(code, message), do: %{code: code, message: message}
end
