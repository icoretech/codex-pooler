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

  @reservation_window_lock_space "api_key_reservation_window"

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

  # Locking a key for a runtime turn comes in three modes, and a transaction
  # takes one mode per key.
  #
  # The reader lock (`FOR SHARE`: `lock_for_read/1`, `capture/1`,
  # `authorize_turn_for_read/2`) is a consistent read of `status` and
  # `runtime_revocation_epoch` for a transaction that never updates or deletes
  # the row and does not use it as a per-key mutex. Readers of one key hold the
  # row together and never block foreign-key `FOR KEY SHARE` checks, while a
  # status or epoch change waits for every reader still holding the row.
  #
  # The reservation mode (`authorize_turn/2`) needs both the consistent read and
  # a key-wide mutex, because a reservation enforces window limits summed over
  # the whole key while locking only the effective policy binding. It takes the
  # reader lock for the read and a transaction-scoped advisory lock for the
  # mutex, so same-key reservations still serialize with each other while every
  # reader -- owner-lease renewal, catalog authorization, websocket claim,
  # replay, finalization -- stops queueing behind them. The `api_keys` row
  # itself must not be the mutex: a row lock is held to commit, so it would
  # cover the whole reservation write set and make each reader wait for it.
  #
  # The writer lock (`FOR UPDATE`: `prepare_status_transition/2`) belongs to a
  # transaction that later writes the row.
  #
  # Never take the writer lock, or write the row, after the reader lock in the
  # same transaction: two readers upgrading their lock deadlock. Within one
  # transaction the advisory mutex is taken before the row, so two reservations
  # cannot order the two objects differently.

  @spec lock_for_read(Ecto.UUID.t() | nil) :: APIKey.t() | nil
  def lock_for_read(api_key_id) do
    require_transaction!()
    lock_api_key(api_key_id, :read)
  end

  @spec capture(APIKey.t() | Ecto.UUID.t()) :: {:ok, epoch()} | {:error, disposition()}
  def capture(api_key_or_id) do
    case lock_for_read(api_key_id(api_key_or_id)) do
      %APIKey{status: @active_status, runtime_revocation_epoch: epoch} -> {:ok, epoch}
      %APIKey{} = api_key -> disabled_disposition(api_key)
      nil -> missing_disposition()
    end
  end

  @spec authorize_turn(APIKey.t() | Ecto.UUID.t(), epoch()) ::
          {:ok, authorization()} | {:error, disposition()}
  def authorize_turn(api_key_or_id, captured_epoch) do
    require_transaction!()

    api_key_or_id
    |> api_key_id()
    |> lock_reservation_window()
    |> lock_api_key(:read)
    |> turn_authorization(captured_epoch)
  end

  @spec authorize_turn_for_read(APIKey.t() | Ecto.UUID.t(), epoch()) ::
          {:ok, authorization()} | {:error, disposition()}
  def authorize_turn_for_read(api_key_or_id, captured_epoch) do
    api_key_or_id
    |> api_key_id()
    |> lock_for_read()
    |> turn_authorization(captured_epoch)
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

    case lock_api_key(api_key_id(api_key_or_id), :write) do
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

  defp turn_authorization(
         %APIKey{status: @active_status, runtime_revocation_epoch: epoch} = api_key,
         epoch
       ),
       do: {:ok, %{api_key: api_key, runtime_revocation_epoch: epoch}}

  defp turn_authorization(
         %APIKey{status: @active_status, runtime_revocation_epoch: epoch},
         _captured_epoch
       ),
       do: stale_epoch_disposition(epoch)

  defp turn_authorization(%APIKey{} = api_key, _captured_epoch),
    do: disabled_disposition(api_key)

  defp turn_authorization(nil, _captured_epoch), do: missing_disposition()

  # `pg_advisory_xact_lock/2` keeps this mutex in its own two-argument lock
  # space, so it cannot collide with the single-argument advisory locks taken
  # elsewhere, and PostgreSQL releases it at commit or rollback without a
  # matching unlock. A key id that hashes to the same 32-bit value as another
  # one only serializes two keys that did not have to serialize; it never
  # admits a turn that the window limits would deny.
  defp lock_reservation_window(nil), do: nil

  defp lock_reservation_window(api_key_id) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [@reservation_window_lock_space, api_key_id]
    )

    api_key_id
  end

  defp lock_api_key(nil, _mode), do: nil

  defp lock_api_key(api_key_id, :read) do
    Repo.one(from api_key in APIKey, where: api_key.id == ^api_key_id, lock: "FOR SHARE")
  end

  defp lock_api_key(api_key_id, :write) do
    Repo.one(from api_key in APIKey, where: api_key.id == ^api_key_id, lock: "FOR UPDATE")
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
