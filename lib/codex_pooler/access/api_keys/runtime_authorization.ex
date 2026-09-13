defmodule CodexPooler.Access.APIKeys.RuntimeAuthorization do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeys.Errors
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @active_status "active"
  @paused_status "paused"
  @revoked_status "revoked"
  @disabling_statuses [@paused_status, @revoked_status]
  @active_pool_status "active"

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
              required(:code) =>
                :api_key_paused
                | :api_key_revoked
                | :api_key_inactive
                | :api_key_runtime_epoch_stale
                | :api_key_expired
                | :api_key_missing
                | :pool_inactive,
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
  #
  # An authorization (`capture/1` and both turn modes) reads more than the key:
  # one statement returns the key row under the reader lock, the status of the
  # key's Pool, and the database clock, and the key must be active, unexpired
  # and in an active Pool. `lock_for_read/1` stays a plain key read, because its
  # callers settle work that was already admitted and must not be refused.
  #
  # Only the key row is locked (`FOR SHARE OF` the key). Any update or delete of
  # that row -- a status, epoch, expiry or Pool move, or the delete itself --
  # still waits for every authorization holding it, so an expiry edit or a key
  # delete is ordered exactly like a pause. The Pool row is read, not locked:
  # every turn of every key in the Pool would otherwise share-lock the same row,
  # and a Pool delete locks the Pool row before it cascades into `api_keys`,
  # which is the opposite order to an authorization that locked the key first.
  # A Pool change that committed before the statement started is refused; an
  # authorization whose statement read the Pool as active before the change
  # committed is work admitted ahead of that change and drains like any other,
  # while the Pool event prompts open sockets to reread.
  #
  # Expiry is compared with the database clock read by that same statement, so
  # every node refuses the same key from the same instant whatever its own
  # clock says.

  @spec lock_for_read(Ecto.UUID.t() | nil) :: APIKey.t() | nil
  def lock_for_read(api_key_id) do
    require_transaction!()
    lock_api_key(api_key_id, :read)
  end

  @spec capture(APIKey.t() | Ecto.UUID.t()) :: {:ok, epoch()} | {:error, disposition()}
  def capture(api_key_or_id) do
    require_transaction!()

    case lock_authorization_snapshot(api_key_id(api_key_or_id)) do
      %{api_key: %APIKey{status: @active_status}} = snapshot ->
        with {:ok, authorization} <- usable_authorization(snapshot),
             do: {:ok, authorization.runtime_revocation_epoch}

      %{api_key: %APIKey{} = api_key} ->
        disabled_disposition(api_key)

      nil ->
        missing_disposition()
    end
  end

  @spec authorize_turn(APIKey.t() | Ecto.UUID.t(), epoch()) ::
          {:ok, authorization()} | {:error, disposition()}
  def authorize_turn(api_key_or_id, captured_epoch) do
    require_transaction!()

    api_key_or_id
    |> api_key_id()
    |> lock_reservation_window()
    |> lock_authorization_snapshot()
    |> turn_authorization(captured_epoch)
  end

  @spec authorize_turn_for_read(APIKey.t() | Ecto.UUID.t(), epoch()) ::
          {:ok, authorization()} | {:error, disposition()}
  def authorize_turn_for_read(api_key_or_id, captured_epoch) do
    require_transaction!()

    api_key_or_id
    |> api_key_id()
    |> lock_authorization_snapshot()
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

  # A key moved to another Pool leaves every authorization captured under its
  # previous Pool stale: an open socket, a claim or a reservation still acts
  # for the previous Pool, and the key row alone would authorize it in the new
  # one. The move therefore advances the runtime epoch, so the stale-epoch
  # fence refuses those authorizations exactly as after a pause. A move that
  # also disables the key advances the epoch once, not twice.
  @spec advance_epoch_for_pool_move(status_transition(), Ecto.UUID.t() | nil) ::
          status_transition()
  def advance_epoch_for_pool_move(%{api_key: %APIKey{pool_id: pool_id}} = transition, pool_id),
    do: transition

  def advance_epoch_for_pool_move(%{api_key: %APIKey{} = api_key} = transition, _target_pool_id) do
    %{
      transition
      | runtime_revocation_epoch:
          max(transition.runtime_revocation_epoch, api_key.runtime_revocation_epoch + 1)
    }
  end

  # An edit that moves the key or changes its expiry changes what authorizations
  # already open would decide, even when the submitted status disables nothing,
  # so it has to reach them as an event that prompts a reread.
  @spec reread_required?(APIKey.t(), APIKey.t()) :: boolean()
  def reread_required?(%APIKey{} = previous, %APIKey{} = updated) do
    previous.pool_id != updated.pool_id or
      not same_expiry?(previous.expires_at, updated.expires_at)
  end

  defp same_expiry?(nil, nil), do: true

  defp same_expiry?(%DateTime{} = previous, %DateTime{} = updated),
    do: DateTime.compare(previous, updated) == :eq

  defp same_expiry?(_previous, _updated), do: false

  # A key that no longer exists refuses with the epoch the caller captured, so
  # a holder of that authorization -- an open socket -- can latch revocation on
  # the same terms as a pause instead of treating the refusal as a generic
  # error.
  defp turn_authorization(nil, captured_epoch), do: missing_disposition(captured_epoch)

  defp turn_authorization(
         %{api_key: %APIKey{status: @active_status, runtime_revocation_epoch: epoch}},
         captured_epoch
       )
       when epoch != captured_epoch,
       do: stale_epoch_disposition(epoch)

  defp turn_authorization(%{api_key: %APIKey{status: @active_status}} = snapshot, _epoch),
    do: usable_authorization(snapshot)

  defp turn_authorization(%{api_key: %APIKey{} = api_key}, _captured_epoch),
    do: disabled_disposition(api_key)

  defp usable_authorization(%{api_key: %APIKey{} = api_key} = snapshot) do
    cond do
      expired?(api_key, snapshot.database_now) ->
        expired_disposition(api_key)

      snapshot.pool_status != @active_pool_status ->
        pool_inactive_disposition(api_key)

      true ->
        {:ok, %{api_key: api_key, runtime_revocation_epoch: api_key.runtime_revocation_epoch}}
    end
  end

  # Usable only while the expiry is still ahead, the same boundary upgrade-time
  # authentication applies.
  defp expired?(%APIKey{expires_at: nil}, _database_now), do: false

  defp expired?(%APIKey{expires_at: %DateTime{} = expires_at}, %DateTime{} = database_now),
    do: DateTime.compare(expires_at, database_now) != :gt

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

  defp lock_authorization_snapshot(nil), do: nil

  defp lock_authorization_snapshot(api_key_id) do
    Repo.one(
      from api_key in APIKey,
        left_join: pool in Pool,
        on: pool.id == api_key.pool_id,
        where: api_key.id == ^api_key_id,
        lock: fragment("FOR SHARE OF ?", api_key),
        select: %{
          api_key: api_key,
          pool_status: pool.status,
          database_now: type(fragment("clock_timestamp()"), :utc_datetime_usec)
        }
    )
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

  defp expired_disposition(%APIKey{} = api_key) do
    {:error,
     Errors.access_error(:api_key_expired, "api key is expired")
     |> Map.put(:disabling_epoch, api_key.runtime_revocation_epoch)}
  end

  defp pool_inactive_disposition(%APIKey{} = api_key) do
    {:error,
     Errors.access_error(:pool_inactive, "pool is not active")
     |> Map.put(:disabling_epoch, api_key.runtime_revocation_epoch)}
  end

  defp stale_epoch_disposition(epoch) do
    {:error,
     Errors.access_error(:api_key_runtime_epoch_stale, "api key runtime authorization is stale")
     |> Map.put(:disabling_epoch, epoch)}
  end

  defp missing_disposition,
    do: {:error, Errors.access_error(:api_key_missing, "api key is required")}

  defp missing_disposition(captured_epoch)
       when is_integer(captured_epoch) and captured_epoch >= 0 do
    {:error,
     Errors.access_error(:api_key_missing, "api key is required")
     |> Map.put(:disabling_epoch, captured_epoch)}
  end

  defp missing_disposition(_captured_epoch), do: missing_disposition()

  defp api_key_id(%APIKey{id: id}), do: id
  defp api_key_id(id) when is_binary(id), do: id
  defp api_key_id(_api_key), do: nil

  defp require_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "runtime API key authorization requires an active transaction"
    end
  end
end
