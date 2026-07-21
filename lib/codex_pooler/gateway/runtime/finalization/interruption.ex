defmodule CodexPooler.Gateway.Runtime.Finalization.Interruption do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Repo

  require Logger

  @default_reconnect_window_seconds 300

  @type opts :: RequestOptions.t()
  @type session_ref :: CodexSession.t() | Ecto.UUID.t()

  @session_interrupted CodexSession.interrupted_status()
  @session_closed CodexSession.closed_status()
  @turn_in_progress CodexTurn.in_progress_status()
  @turn_succeeded CodexTurn.succeeded_status()
  @turn_failed CodexTurn.failed_status()
  @turn_interrupted CodexTurn.interrupted_status()

  @spec interrupt_codex_session(session_ref(), opts()) :: {:ok, term()} | {:error, term()}
  def interrupt_codex_session(%CodexSession{id: id}, opts), do: interrupt_codex_session(id, opts)

  def interrupt_codex_session(session_id, %RequestOptions{} = opts) when is_binary(session_id) do
    interrupt_session(session_id, opts, interrupt_reason(opts))
  end

  def interrupt_codex_session(_session_id, _opts), do: {:ok, :ok}

  @spec interrupt_codex_turn(session_ref(), opts()) :: {:ok, term()} | {:error, term()}
  def interrupt_codex_turn(%CodexSession{id: id}, opts), do: interrupt_codex_turn(id, opts)

  def interrupt_codex_turn(session_id, %RequestOptions{} = opts) when is_binary(session_id) do
    case request_id(opts) do
      nil -> {:ok, %{interrupted_turn_count: 0}}
      request_id -> interrupt_session_turn(session_id, request_id, opts, interrupt_reason(opts))
    end
  end

  def interrupt_codex_turn(_session_id, _opts), do: {:ok, %{interrupted_turn_count: 0}}

  @spec recover_owner_lifecycle_leftovers(session_ref(), atom() | String.t(), opts()) ::
          {:ok, term()} | {:error, term()}
  def recover_owner_lifecycle_leftovers(%CodexSession{id: id}, owner_reason, opts),
    do: recover_owner_lifecycle_leftovers(id, owner_reason, opts)

  def recover_owner_lifecycle_leftovers(session_id, owner_reason, %RequestOptions{} = opts)
      when is_binary(session_id) do
    reason = owner_recovery_reason(owner_reason)

    case interrupt_session(session_id, opts, reason) do
      {:ok, _result} = ok ->
        ok

      {:error, failure} = error ->
        log_owner_lifecycle_recovery_failure(session_id, reason, failure)
        error
    end
  end

  def recover_owner_lifecycle_leftovers(_session_id, _owner_reason, _opts), do: {:ok, :ok}

  defp interrupt_session(session_id, %RequestOptions{} = opts, reason) do
    now = now()
    reconnect_window = reconnect_window_seconds(opts)
    next_status = if reconnect_window > 0, do: @session_interrupted, else: @session_closed
    lease_expires_at = if reconnect_window > 0, do: DateTime.add(now, reconnect_window, :second)

    Repo.transaction(fn ->
      case codex_session_for_update(session_id) do
        %CodexSession{} = session ->
          in_progress_turns = in_progress_turns_for_session(session_id)
          Enum.each(in_progress_turns, &interrupt_turn!(&1, reason, now))

          session
          |> Ecto.Changeset.change(%{
            status: next_status,
            disconnected_at: now,
            closed_at: if(next_status == @session_closed, do: now, else: nil),
            owner_lease_expires_at: lease_expires_at,
            last_heartbeat_at: now,
            updated_at: now
          })
          |> Repo.update!()

          %{interrupted_turn_count: length(in_progress_turns)}

        nil ->
          %{interrupted_turn_count: 0}
      end
    end)
    |> unwrap_transaction()
  end

  defp interrupt_session_turn(session_id, request_id, %RequestOptions{} = opts, reason) do
    now = now()
    reconnect_window = reconnect_window_seconds(opts)
    next_status = if reconnect_window > 0, do: @session_interrupted, else: @session_closed
    lease_expires_at = if reconnect_window > 0, do: DateTime.add(now, reconnect_window, :second)

    Repo.transaction(fn ->
      session_id
      |> codex_session_for_update()
      |> interrupt_session_turn_for_request(
        session_id,
        request_id,
        reason,
        now,
        next_status,
        lease_expires_at
      )
    end)
    |> unwrap_transaction()
  end

  defp interrupt_session_turn_for_request(
         nil,
         _session_id,
         _request_id,
         _reason,
         _now,
         _status,
         _expires_at
       ),
       do: %{interrupted_turn_count: 0}

  defp interrupt_session_turn_for_request(
         %CodexSession{} = session,
         session_id,
         request_id,
         reason,
         now,
         next_status,
         lease_expires_at
       ) do
    interrupted_count = interrupt_turn_for_request(session_id, request_id, reason, now)

    session
    |> Ecto.Changeset.change(%{
      status: next_status,
      disconnected_at: now,
      closed_at: if(next_status == @session_closed, do: now, else: nil),
      owner_lease_expires_at: lease_expires_at,
      last_heartbeat_at: now,
      updated_at: now
    })
    |> Repo.update!()

    %{interrupted_turn_count: interrupted_count}
  end

  defp interrupt_turn_for_request(session_id, request_id, reason, now) do
    case in_progress_turn_for_request(session_id, request_id) do
      %CodexTurn{} = turn ->
        interrupt_turn!(turn, reason, now)
        1

      nil ->
        0
    end
  end

  defp interrupt_turn!(%CodexTurn{} = turn, reason, now) do
    request = request_for_update(turn.request_id)
    attempt = latest_attempt_for_update(turn.request_id)

    cond do
      request_completed_successfully?(request, attempt) ->
        complete_interrupted_turn!(turn, attempt, @turn_succeeded, nil, now)

      request && request.status in ["accepted", "in_progress"] && active_attempt?(attempt) ->
        finalize_interrupted_request!(request, attempt, reason)
        complete_interrupted_turn!(turn, attempt, @turn_interrupted, reason, now)

      request && request.status in ["accepted", "in_progress"] ->
        request
        |> Ecto.Changeset.change(%{
          status: "failed",
          usage_status: "usage_unknown",
          completed_at: now,
          response_status_code: 499,
          last_error_code: reason
        })
        |> Repo.update!()

        complete_interrupted_turn!(turn, attempt, @turn_interrupted, reason, now)

      true ->
        complete_interrupted_turn!(
          turn,
          attempt,
          terminal_turn_status(request),
          terminal_error_code(request),
          now
        )
    end
  end

  defp finalize_interrupted_request!(request, attempt, reason) do
    case Accounting.finalize_request(request, attempt, %{
           request_status: "failed",
           attempt_status: "failed",
           response_status_code: 499,
           last_error_code: reason,
           error_message: "websocket client disconnected before the turn completed",
           usage: %{status: "usage_unknown", source: reason}
         }) do
      {:ok, _result} -> :ok
      {:error, error} -> Repo.rollback({:interrupt_accounting_failed, error})
    end
  rescue
    exception ->
      Repo.rollback({:interrupt_accounting_failed, exception})
  end

  defp in_progress_turns_for_session(session_id) do
    Repo.all(
      from turn in CodexTurn,
        where: turn.codex_session_id == ^session_id and turn.status == ^@turn_in_progress,
        order_by: [asc: turn.started_at]
    )
  end

  defp in_progress_turn_for_request(session_id, request_id) do
    Repo.one(
      from turn in CodexTurn,
        join: request in Request,
        on: request.id == turn.request_id,
        where:
          turn.codex_session_id == ^session_id and turn.status == ^@turn_in_progress and
            request.correlation_id == ^request_id,
        order_by: [desc: turn.started_at],
        limit: 1
    )
  end

  defp latest_attempt_for_update(request_id) do
    Repo.one(
      from attempt in Attempt,
        where: attempt.request_id == ^request_id,
        order_by: [desc: attempt.attempt_number],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  @spec codex_session_for_update(Ecto.UUID.t()) :: CodexSession.t() | nil
  defp codex_session_for_update(session_id) do
    Repo.one(
      from session in CodexSession,
        where: session.id == ^session_id,
        lock: "FOR UPDATE"
    )
  end

  @spec request_for_update(Ecto.UUID.t()) :: Request.t() | nil
  defp request_for_update(request_id) do
    Repo.one(
      from request in Request,
        where: request.id == ^request_id,
        lock: "FOR UPDATE"
    )
  end

  defp active_attempt?(%Attempt{status: status}), do: status in ["queued", "in_progress"]
  defp active_attempt?(_attempt), do: false

  defp request_completed_successfully?(%Request{status: "succeeded"}, _attempt), do: true
  defp request_completed_successfully?(_request, %Attempt{status: "succeeded"}), do: true
  defp request_completed_successfully?(_request, _attempt), do: false

  defp terminal_turn_status(%Request{status: "succeeded"}), do: @turn_succeeded

  defp terminal_turn_status(%Request{status: "failed", last_error_code: error_code})
       when error_code in ["client_disconnected", "owner_drained", "owner_unavailable"],
       do: @turn_interrupted

  defp terminal_turn_status(%Request{status: status})
       when status in ["failed", "rejected", "cancelled"],
       do: @turn_failed

  defp terminal_turn_status(_request), do: @turn_interrupted

  defp terminal_error_code(%Request{status: "succeeded"}), do: nil
  defp terminal_error_code(%Request{last_error_code: code}) when is_binary(code), do: code
  defp terminal_error_code(_request), do: "client_disconnected"

  defp complete_interrupted_turn!(turn, attempt, status, error_code, now) do
    turn
    |> Ecto.Changeset.change(%{
      status: status,
      error_code: error_code,
      final_attempt_id: attempt && attempt.id,
      completed_at: now,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp reconnect_window_seconds(%RequestOptions{} = opts) do
    case opts.continuity.reconnect_window_seconds || @default_reconnect_window_seconds do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _value -> @default_reconnect_window_seconds
    end
  end

  defp interrupt_reason(%RequestOptions{runtime: %{interrupt_reason: reason}})
       when is_binary(reason) and reason != "",
       do: reason

  defp interrupt_reason(%RequestOptions{}), do: "client_disconnected"

  defp request_id(%RequestOptions{request_metadata: %{request_id: request_id}})
       when is_binary(request_id) do
    request_id = String.trim(request_id)
    if request_id == "", do: nil, else: request_id
  end

  defp request_id(%RequestOptions{}), do: nil

  defp owner_recovery_reason(:owner_drained), do: "owner_drained"
  defp owner_recovery_reason("owner_drained"), do: "owner_drained"
  defp owner_recovery_reason(:owner_crashed), do: "owner_crashed"
  defp owner_recovery_reason("owner_crashed"), do: "owner_crashed"
  defp owner_recovery_reason(_reason), do: "owner_unavailable"

  defp log_owner_lifecycle_recovery_failure(session_id, reason, failure) do
    Logger.warning(
      "websocket owner lifecycle recovery failed " <>
        "codex_session_id=#{safe_log_value(session_id)} " <>
        "recovery_reason=#{safe_log_value(reason)} " <>
        "failure_reason=#{safe_log_value(Metadata.safe_reason(failure))}"
    )

    :ok
  end

  defp safe_log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
