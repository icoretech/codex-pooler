defmodule CodexPooler.Access.APIKeys.Queries do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}
  alias CodexPooler.Access.APIKeys.{Errors, Policy}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Authorization, as: PoolAuthorization
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type api_key_with_policy :: %{
          required(:api_key) => APIKey.t(),
          required(:policy) => map(),
          required(:policy_bindings) => [%APIKeyPolicyBinding{}]
        }

  @pool_status_active "active"

  @spec list_api_keys(Scope.t()) :: {:ok, [APIKey.t()]} | {:error, access_error()}
  def list_api_keys(%Scope{} = scope) do
    with {:ok, pools} <-
           PoolAuthorization.list_pools_for_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             ["active"]
           ) do
      {:ok, list_api_keys_for_authorized_pools(pools)}
    end
  end

  def list_api_keys(_scope),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  defp list_api_keys_for_authorized_pools([]), do: []

  defp list_api_keys_for_authorized_pools(pools) do
    pool_ids = Enum.map(pools, & &1.id)

    keys_by_pool_id =
      APIKey
      |> where([key], key.pool_id in ^pool_ids)
      |> order_by([key], asc: key.pool_id, desc: key.created_at)
      |> Repo.all()
      |> Enum.group_by(& &1.pool_id)

    Enum.flat_map(pools, &Map.get(keys_by_pool_id, &1.id, []))
  end

  @spec count_api_keys_by_pool_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  def count_api_keys_by_pool_ids(pool_ids) when is_list(pool_ids) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    counts =
      case pool_ids do
        [] ->
          %{}

        _ ->
          Repo.all(
            from key in APIKey,
              join: pool in Pool,
              on: pool.id == key.pool_id,
              where: key.pool_id in ^pool_ids,
              where: pool.status == ^@pool_status_active,
              group_by: key.pool_id,
              select: {key.pool_id, count(key.id)}
          )
          |> Map.new()
      end

    Enum.into(pool_ids, %{}, fn pool_id ->
      {pool_id, Map.get(counts, pool_id, 0)}
    end)
  end

  def count_api_keys_by_pool_ids(_pool_ids), do: %{}

  @spec api_key_ids_for_pool(Pool.t()) :: [Ecto.UUID.t()]
  def api_key_ids_for_pool(%Pool{id: pool_id}) do
    Repo.all(
      from key in APIKey,
        where: key.pool_id == ^pool_id,
        select: key.id
    )
  end

  def api_key_ids_for_pool(_pool), do: []

  @spec list_api_keys_with_policy(Scope.t()) ::
          {:ok, [api_key_with_policy()]} | {:error, access_error()}
  def list_api_keys_with_policy(%Scope{} = scope) do
    with {:ok, api_keys} <- list_api_keys(scope) do
      {:ok, Enum.map(api_keys, &api_key_with_policy/1)}
    end
  end

  def list_api_keys_with_policy(_scope),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec list_api_keys(Scope.t(), Pool.t() | Ecto.UUID.t()) ::
          {:ok, [APIKey.t()]} | {:error, access_error()}
  def list_api_keys(%Scope{} = scope, pool_or_id) do
    with %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: pool.id
           ) do
      {:ok,
       Repo.all(from k in APIKey, where: k.pool_id == ^pool.id, order_by: [desc: k.created_at])}
    else
      nil -> {:error, Errors.access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  @spec get_api_key(Scope.t(), Ecto.UUID.t()) :: {:ok, APIKey.t()} | {:error, access_error()}
  def get_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id) do
    with %APIKey{} = api_key <- Repo.get(APIKey, api_key_id),
         {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ) do
      {:ok, api_key}
    else
      nil ->
        {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

      {:error, %{code: :capability_denied}} ->
        {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

      {:error, _reason} = error ->
        error
    end
  end

  def get_api_key(_scope, _api_key_id),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec get_api_key_with_policy(Scope.t(), Ecto.UUID.t()) ::
          {:ok, api_key_with_policy()} | {:error, access_error()}
  def get_api_key_with_policy(%Scope{} = scope, api_key_id) when is_binary(api_key_id) do
    with {:ok, api_key} <- get_api_key(scope, api_key_id) do
      {:ok, api_key_with_policy(api_key)}
    end
  end

  def get_api_key_with_policy(_scope, _api_key_id),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  defp api_key_with_policy(%APIKey{} = api_key) do
    bindings =
      Repo.all(
        from binding in APIKeyPolicyBinding,
          where: binding.api_key_id == ^api_key.id,
          order_by: [asc: binding.binding_scope, asc: binding.model_identifier]
      )

    %{
      api_key: api_key,
      policy: %{
        model_mode: Policy.allow_list_mode(api_key.allowed_model_identifiers, :models),
        enforced_model_identifier: api_key.enforced_model_identifier,
        enforced_reasoning_effort: api_key.enforced_reasoning_effort,
        maximum_reasoning_effort: api_key.maximum_reasoning_effort,
        reasoning_policy_mode: reasoning_policy_mode(api_key),
        enforced_service_tier: api_key.enforced_service_tier
      },
      policy_bindings: bindings
    }
  end

  defp reasoning_policy_mode(%APIKey{
         enforced_reasoning_effort: nil,
         maximum_reasoning_effort: nil
       }),
       do: :unrestricted

  defp reasoning_policy_mode(%APIKey{
         enforced_reasoning_effort: nil,
         maximum_reasoning_effort: maximum
       })
       when is_binary(maximum),
       do: :allow_up_to

  defp reasoning_policy_mode(%APIKey{
         enforced_reasoning_effort: enforced,
         maximum_reasoning_effort: nil
       })
       when is_binary(enforced),
       do: :always_use

  defp normalize_pool(%Pool{} = pool), do: pool
  defp normalize_pool(id) when is_binary(id), do: Pools.get_active_pool(id)
  defp normalize_pool(_pool_or_id), do: nil
end
