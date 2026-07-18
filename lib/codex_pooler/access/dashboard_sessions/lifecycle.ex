defmodule CodexPooler.Access.DashboardSessions.Lifecycle do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions
  alias CodexPooler.Repo

  @type mutation_result(value) :: {:ok, value} | {:error, term()}

  @spec run(APIKey.t(), String.t(), (-> mutation_result(value))) :: mutation_result(value)
        when value: term()
  def run(%APIKey{} = previous_api_key, cause, mutation) when is_function(mutation, 0) do
    Repo.transaction(fn ->
      case mutation.() do
        {:ok, value} ->
          DashboardSessions.delete_all_for_api_key(previous_api_key.id)
          value

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> normalize_result()
    |> tap(fn
      {:ok, value} ->
        value
        |> api_key(previous_api_key)
        |> DashboardSessions.broadcast_invalidation(cause)

      {:error, _reason} ->
        :ok
    end)
  end

  defp normalize_result({:ok, value}), do: {:ok, value}
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp api_key(%APIKey{} = api_key, _previous_api_key), do: api_key
  defp api_key(%{api_key: %APIKey{} = api_key}, _previous_api_key), do: api_key
  defp api_key(_value, %APIKey{} = previous_api_key), do: previous_api_key
end
