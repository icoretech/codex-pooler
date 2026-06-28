defmodule CodexPooler.MCP.Tools.PoolMetadata do
  @moduledoc """
  Metadata-only MCP tool registry facade for pools, upstreams, and Pool API keys.
  """

  alias CodexPooler.MCP.Tools.PoolMetadata.{ApiKeys, Pools, Upstreams}

  @spec tools() :: [map()]
  def tools do
    Pools.tools() ++ Upstreams.tools() ++ ApiKeys.tools()
  end

  @spec list_pools(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  defdelegate list_pools(arguments, context), to: Pools

  @spec get_pool(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  defdelegate get_pool(arguments, context), to: Pools

  @spec list_upstreams(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  defdelegate list_upstreams(arguments, context), to: Upstreams

  @spec get_upstream(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  defdelegate get_upstream(arguments, context), to: Upstreams

  @spec list_pool_api_keys(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  defdelegate list_pool_api_keys(arguments, context), to: ApiKeys

  @spec get_pool_api_key(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  defdelegate get_pool_api_key(arguments, context), to: ApiKeys
end
