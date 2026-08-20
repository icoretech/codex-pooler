defmodule CodexPooler.Access.APIKeys.RuntimeAuthorization do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeys.Errors
  alias CodexPooler.Repo

  @active_status "active"
  @paused_status "paused"
  @revoked_status "revoked"
  @disabling_statuses [@paused_status, @revoked_status]

  @type epoch :: non_neg_integer()
  @type authorization :: %{
          required(:api_key) => APIKey.t(),
          required(:runtime_revocation_epoch) => epoch()
        }
  @type status_transition :: %{
          required(:api_key) => APIKey.t(),
          required(:runtime_revocation_epoch) => epoch(),
          required(:effective_disabling_transition?) => boolean()
        }
  @type disposition ::
          Errors.access_error()
          | %{
              required(:code) => :api_key_paused | :api_key_revoked,
              required(:message) => String.t(),
              required(:disabling_epoch) => epoch()
            }
          | %{
              required(:code) => :api_key_runtime_epoch_stale,
              required(:message) => String.t(),
              required(:disabling_epoch) => epoch()
            }

  @spec capture(APIKey.t() | Ecto.UUID.t()) :: {:ok, epoch()} | {:error, disposition()}
  def capture(api_key_or_id) do
    require_transaction!()

    case lock_api_key(api_key_id(api_key_or_id)) do
      %APIKey{status: @active_status, runtime_revocation_epoch: epoch} -> {:ok, epoch}
      %APIKey{} = api_key -> disabled_disposition(api_key)
      nil -> missing_disposition()
    end
  end

  @spec authorize_turn(APIKey.t() | Ecto.UUID.t(), epoch()) ::
          {:ok, authorization()} | {:error, disposition()}
  def authorize_turn(api_key_or_id, captured_epoch) do
    require_transaction!()

    case lock_api_key(api_key_id(api_key_or_id)) do
      %APIKey{status: @active_status, runtime_revocation_epoch: ^captured_epoch} = api_key ->
        {:ok, %{api_key: api_key, runtime_revocation_epoch: captured_epoch}}

      %APIKey{status: @active_status, runtime_revocation_epoch: epoch} ->
        stale_epoch_disposition(epoch)

      %APIKey{} = api_key ->
        disabled_disposition(api_key)

      nil ->
        missing_disposition()
    end
  end

  @spec epoch_for_status_change(APIKey.t(), String.t()) :: epoch()
  def epoch_for_status_change(%APIKey{} = api_key, target_status) do
    if target_status in @disabling_statuses and target_status != api_key.status do
      api_key.runtime_revocation_epoch + 1
    else
      api_key.runtime_revocation_epoch
    end
  end

  @spec prepare_status_transition(APIKey.t() | Ecto.UUID.t(), String.t()) ::
          {:ok, status_transition()} | {:error, disposition()}
  def prepare_status_transition(api_key_or_id, target_status) do
    require_transaction!()

    case lock_api_key(api_key_id(api_key_or_id)) do
      %APIKey{} = api_key ->
        runtime_revocation_epoch = epoch_for_status_change(api_key, target_status)

        {:ok,
         %{
           api_key: api_key,
           runtime_revocation_epoch: runtime_revocation_epoch,
           effective_disabling_transition?:
             runtime_revocation_epoch > api_key.runtime_revocation_epoch
         }}

      nil ->
        missing_disposition()
    end
  end

  defp lock_api_key(nil), do: nil

  defp lock_api_key(api_key_id) do
    Repo.one(
      from api_key in APIKey,
        where: api_key.id == ^api_key_id,
        lock: "FOR UPDATE"
    )
  end

  defp disabled_disposition(%APIKey{status: @paused_status} = api_key) do
    {:error,
     Errors.access_error(:api_key_paused, "api key is paused")
     |> Map.put(:disabling_epoch, api_key.runtime_revocation_epoch)}
  end

  defp disabled_disposition(%APIKey{status: @revoked_status} = api_key) do
    {:error,
     Errors.access_error(:api_key_revoked, "api key is revoked")
     |> Map.put(:disabling_epoch, api_key.runtime_revocation_epoch)}
  end

  defp disabled_disposition(%APIKey{} = api_key) do
    {:error,
     Errors.access_error(:api_key_inactive, "api key is inactive")
     |> Map.put(:disabling_epoch, api_key.runtime_revocation_epoch)}
  end

  defp stale_epoch_disposition(epoch) do
    {:error,
     Errors.access_error(:api_key_runtime_epoch_stale, "api key runtime authorization is stale")
     |> Map.put(:disabling_epoch, epoch)}
  end

  defp missing_disposition,
    do: {:error, Errors.access_error(:api_key_missing, "api key is required")}

  defp api_key_id(%APIKey{id: id}), do: id
  defp api_key_id(id) when is_binary(id), do: id
  defp api_key_id(_api_key), do: nil

  defp require_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "runtime API key authorization requires an active transaction"
    end
  end
end
