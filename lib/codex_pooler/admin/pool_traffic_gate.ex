defmodule CodexPooler.Admin.PoolTrafficGate do
  @moduledoc false
  use CodexPooler.Schema

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Repo

  @primary_key {:operator_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @crash_lease_seconds 30
  @completion_cooldown_ms 1_000
  @lock_contention_retry_ms 1_000

  @type run_result(result) ::
          {:ok, result, non_neg_integer()}
          | {:busy, pos_integer()}
          | {:error, :gate_unavailable | :stale_owner}

  @type finish_result ::
          {:ok, non_neg_integer()} | {:error, :gate_unavailable | :stale_owner}

  schema "admin_pool_traffic_gates" do
    field :owner_token, :binary_id
    field :lease_expires_at, :utc_datetime_usec
    field :cooldown_until, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @spec run(Scope.t(), Ecto.UUID.t(), (-> result)) :: run_result(result) when result: term()
  def run(%Scope{user: %User{id: operator_id}} = scope, owner_token, operation)
      when is_function(operation, 0) do
    with {:ok, operator_id} <- Ecto.UUID.cast(operator_id),
         {:ok, owner_token} <- Ecto.UUID.cast(owner_token) do
      Repo.checkout(fn -> run_checked_out(scope, operator_id, owner_token, operation) end)
    else
      :error -> {:error, :gate_unavailable}
    end
  end

  def run(_scope, _owner_token, _operation), do: {:error, :gate_unavailable}

  @spec finish(Scope.t(), Ecto.UUID.t()) :: finish_result()
  def finish(%Scope{user: %User{id: operator_id}}, owner_token) do
    with {:ok, operator_id} <- Ecto.UUID.cast(operator_id),
         {:ok, owner_token} <- Ecto.UUID.cast(owner_token) do
      finish_owner(operator_id, owner_token)
    else
      :error -> {:error, :gate_unavailable}
    end
  end

  def finish(_scope, _owner_token), do: {:error, :gate_unavailable}

  defp run_checked_out(scope, operator_id, owner_token, operation) do
    case try_advisory_lock(operator_id) do
      {:ok, lock_key} -> with_advisory_lock(scope, operator_id, owner_token, operation, lock_key)
      :busy -> {:busy, @lock_contention_retry_ms}
      {:error, :gate_unavailable} = error -> error
    end
  end

  defp try_advisory_lock(operator_id) do
    case Repo.query(
           """
           SELECT
             hashtextextended('admin_pool_traffic:' || $1::text, 0),
             pg_try_advisory_lock(
               hashtextextended('admin_pool_traffic:' || $1::text, 0)
             )
           """,
           [operator_id]
         ) do
      {:ok, %{rows: [[lock_key, true]]}} -> {:ok, lock_key}
      {:ok, %{rows: [[_lock_key, false]]}} -> :busy
      {:ok, _result} -> {:error, :gate_unavailable}
      {:error, _reason} -> {:error, :gate_unavailable}
    end
  end

  defp with_advisory_lock(scope, operator_id, owner_token, operation, lock_key) do
    result =
      try do
        claim_and_run(scope, operator_id, owner_token, operation)
      catch
        kind, reason ->
          _ = unlock_advisory_lock(lock_key)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case unlock_advisory_lock(lock_key) do
      :ok -> result
      {:error, :gate_unavailable} = error -> error
    end
  end

  defp claim_and_run(scope, operator_id, owner_token, operation) do
    case claim(operator_id, owner_token) do
      :claimed -> run_claimed(scope, owner_token, operation)
      {:busy, _retry_after_ms} = busy -> busy
      {:error, :gate_unavailable} = error -> error
    end
  end

  defp claim(operator_id, owner_token) do
    case Repo.query(claim_sql(), [operator_id, owner_token, @crash_lease_seconds]) do
      {:ok, %{num_rows: 1}} -> :claimed
      {:ok, %{num_rows: 0}} -> blocked_delay(operator_id)
      {:ok, _result} -> {:error, :gate_unavailable}
      {:error, _reason} -> {:error, :gate_unavailable}
    end
  end

  defp blocked_delay(operator_id) do
    case Repo.query(blocked_delay_sql(), [operator_id]) do
      {:ok, %{rows: [[retry_after_ms]]}} when is_integer(retry_after_ms) ->
        {:busy, max(retry_after_ms, 1)}

      {:ok, _result} ->
        {:error, :gate_unavailable}

      {:error, _reason} ->
        {:error, :gate_unavailable}
    end
  end

  defp run_claimed(scope, owner_token, operation) do
    result = operation.()

    case finish(scope, owner_token) do
      {:ok, cooldown_ms} -> {:ok, result, cooldown_ms}
      {:error, _reason} = error -> error
    end
  catch
    kind, reason ->
      _ = finish(scope, owner_token)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp finish_owner(operator_id, owner_token) do
    case Repo.query(finish_sql(), [operator_id, owner_token, @completion_cooldown_ms]) do
      {:ok, %{rows: [[cooldown_ms]]}} when is_integer(cooldown_ms) ->
        {:ok, cooldown_ms}

      {:ok, %{num_rows: 0}} ->
        {:error, :stale_owner}

      {:ok, _result} ->
        {:error, :gate_unavailable}

      {:error, _reason} ->
        {:error, :gate_unavailable}
    end
  end

  defp unlock_advisory_lock(lock_key) do
    case Repo.query("SELECT pg_advisory_unlock($1)", [lock_key]) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, _result} -> {:error, :gate_unavailable}
      {:error, _reason} -> {:error, :gate_unavailable}
    end
  end

  defp claim_sql do
    """
    INSERT INTO admin_pool_traffic_gates (
      operator_id,
      owner_token,
      lease_expires_at,
      cooldown_until,
      inserted_at,
      updated_at
    )
    VALUES (
      $1::text::uuid,
      $2::text::uuid,
      statement_timestamp() + make_interval(secs => $3::integer),
      statement_timestamp(),
      statement_timestamp(),
      statement_timestamp()
    )
    ON CONFLICT (operator_id) DO UPDATE
    SET owner_token = EXCLUDED.owner_token,
        lease_expires_at = EXCLUDED.lease_expires_at,
        updated_at = statement_timestamp()
    WHERE (
            admin_pool_traffic_gates.owner_token IS NULL
            AND admin_pool_traffic_gates.cooldown_until <= statement_timestamp()
          )
       OR admin_pool_traffic_gates.lease_expires_at <= statement_timestamp()
    RETURNING owner_token
    """
  end

  defp blocked_delay_sql do
    """
    SELECT GREATEST(
      1,
      CEIL(
        EXTRACT(
          EPOCH FROM (
            CASE
              WHEN owner_token IS NULL THEN cooldown_until
              ELSE lease_expires_at
            END - statement_timestamp()
          )
        ) * 1000
      )::bigint
    )
    FROM admin_pool_traffic_gates
    WHERE operator_id = $1::text::uuid
    """
  end

  defp finish_sql do
    """
    UPDATE admin_pool_traffic_gates
    SET owner_token = NULL,
        lease_expires_at = NULL,
        cooldown_until = statement_timestamp() + ($3::integer * interval '1 millisecond'),
        updated_at = statement_timestamp()
    WHERE operator_id = $1::text::uuid
      AND owner_token = $2::text::uuid
    RETURNING CEIL(
      EXTRACT(EPOCH FROM (cooldown_until - statement_timestamp())) * 1000
    )::bigint
    """
  end
end
