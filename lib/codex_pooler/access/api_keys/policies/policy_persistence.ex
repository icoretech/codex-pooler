defmodule CodexPooler.Access.APIKeys.PolicyPersistence do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.{APIKey, APIKeyPolicyBinding}
  alias CodexPooler.Repo

  @type create_result ::
          {:ok,
           %{
             api_key: APIKey.t(),
             raw_key: String.t(),
             policy_bindings: [APIKeyPolicyBinding.t()]
           }}
          | {:error, Ecto.Changeset.t()}
  @type update_policy_result ::
          {:ok, %{api_key: APIKey.t(), policy_bindings: [APIKeyPolicyBinding.t()]}}
          | {:error, Ecto.Changeset.t()}
  @type transaction_result(value) ::
          {:ok, value}
          | {:ok, %{result: value}}
          | {:error, term()}
          | {:error, term(), term(), term()}

  @spec create_api_key(map(), [map()], String.t(), DateTime.t()) :: create_result()
  def create_api_key(api_key_attrs, policy_inputs, raw_key, timestamp) do
    Repo.transaction(fn ->
      with {:ok, api_key} <- Repo.insert(APIKey.changeset(%APIKey{}, api_key_attrs)),
           {:ok, policy_bindings} <-
             insert_api_key_policy_bindings(Repo, policy_inputs, api_key, timestamp) do
        %{api_key: api_key, raw_key: raw_key, policy_bindings: policy_bindings}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec update_api_key_policy_in_transaction(
          APIKey.t(),
          map(),
          [map()],
          DateTime.t(),
          non_neg_integer()
        ) :: update_policy_result()
  def update_api_key_policy_in_transaction(
        api_key,
        update_attrs,
        policy_inputs,
        timestamp,
        runtime_revocation_epoch
      ) do
    if Repo.in_transaction?() do
      changeset =
        api_key
        |> APIKey.changeset(update_attrs)
        |> Ecto.Changeset.put_change(:runtime_revocation_epoch, runtime_revocation_epoch)

      with {:ok, updated_api_key} <- Repo.update(changeset),
           {_count, _rows} <-
             Repo.delete_all(
               from(binding in APIKeyPolicyBinding, where: binding.api_key_id == ^api_key.id)
             ),
           {:ok, bindings} <-
             insert_api_key_policy_bindings(Repo, policy_inputs, updated_api_key, timestamp) do
        {:ok, %{api_key: updated_api_key, policy_bindings: bindings}}
      end
    else
      raise ArgumentError, "API key policy update requires an active transaction"
    end
  end

  @spec normalize_transaction_result(transaction_result(value)) :: {:ok, value} | {:error, term()}
        when value: term()
  def normalize_transaction_result({:ok, %{result: value}}), do: {:ok, value}
  def normalize_transaction_result({:ok, value}), do: {:ok, value}
  def normalize_transaction_result({:error, _operation, value, _changes}), do: {:error, value}
  def normalize_transaction_result({:error, value}), do: {:error, value}

  defp insert_api_key_policy_bindings(repo, policy_inputs, api_key, timestamp) do
    Enum.reduce_while(policy_inputs, {:ok, []}, fn policy_attrs, {:ok, acc} ->
      policy_attrs =
        Map.merge(policy_attrs, %{
          api_key_id: api_key.id,
          created_at: timestamp,
          updated_at: timestamp
        })

      case repo.insert(APIKeyPolicyBinding.changeset(%APIKeyPolicyBinding{}, policy_attrs)) do
        {:ok, binding} -> {:cont, {:ok, [binding | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      {:error, _reason} = error -> error
    end
  end
end
