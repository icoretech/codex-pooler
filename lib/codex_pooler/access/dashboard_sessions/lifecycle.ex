defmodule CodexPooler.Access.DashboardSessions.Lifecycle do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions
  alias CodexPooler.Repo

  @type mutation_result(value) :: {:ok, value} | {:error, term()}

  @spec run(APIKey.t(), String.t(), (-> mutation_result(value))) :: mutation_result(value)
        when value: term()
  def run(%APIKey{} = previous_api_key, cause, mutation) when is_function(mutation, 0) do
    Repo.transact(fn -> run_in_transaction(previous_api_key, cause, mutation) end)
    |> tap(fn
      {:ok, value} ->
        value
        |> api_key(previous_api_key)
        |> DashboardSessions.broadcast_invalidation(cause)

      {:error, _reason} ->
        :ok
    end)
  end

  @spec run_in_transaction(APIKey.t(), String.t(), (-> mutation_result(value))) ::
          mutation_result(value)
        when value: term()
  def run_in_transaction(%APIKey{} = previous_api_key, _cause, mutation)
      when is_function(mutation, 0) do
    if Repo.in_transaction?() do
      case mutation.() do
        {:ok, value} ->
          DashboardSessions.delete_all_for_api_key(previous_api_key.id)
          {:ok, value}

        {:error, _reason} = error ->
          error
      end
    else
      raise ArgumentError, "dashboard session lifecycle requires an active transaction"
    end
  end

  defp api_key(%APIKey{} = api_key, _previous_api_key), do: api_key
  defp api_key(%{api_key: %APIKey{} = api_key}, _previous_api_key), do: api_key
  defp api_key(_value, %APIKey{} = previous_api_key), do: previous_api_key
end
