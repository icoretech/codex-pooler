defmodule CodexPooler.Gateway.Persistence.SessionContinuity.TurnLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession,
    CodexTurn
  }

  alias CodexPooler.Repo

  @type turn_result :: {:ok, CodexTurn.t()} | {:error, term()}
  @type request_ref :: Request.t() | Ecto.UUID.t()
  @type opts :: RequestOptions.t()

  @turn_in_progress CodexTurn.in_progress_status()
  @turn_succeeded CodexTurn.succeeded_status()
  @turn_interrupted CodexTurn.interrupted_status()
  @session_active CodexSession.active_status()
  @owner_lease_active BridgeOwnerLease.active_status()

  @spec duplicate_codex_turn?(CodexSession.t(), Ecto.UUID.t() | String.t()) :: boolean()
  def duplicate_codex_turn?(%CodexSession{id: session_id}, request_id)
      when is_binary(request_id) do
    request_id = String.trim(request_id)

    request_id != "" and
      Repo.exists?(
        from turn in CodexTurn,
          join: request in Request,
          on: request.id == turn.request_id,
          where: turn.codex_session_id == ^session_id and request.correlation_id == ^request_id
      )
  end

  def duplicate_codex_turn?(_session, _request_id), do: false

  @spec start_codex_turn(CodexSession.t(), Request.t(), opts()) :: turn_result()
  def start_codex_turn(
        %CodexSession{} = session,
        %Request{} = request,
        %RequestOptions{} = opts
      ) do
    now = now()
    opts = turn_opts(opts)

    Repo.transaction(fn ->
      locked_session = Repo.get!(CodexSession, session.id, lock: "FOR UPDATE")
      ensure_codex_turn_is_unique!(locked_session, opts)

      sequence =
        Repo.one(
          from turn in CodexTurn,
            where: turn.codex_session_id == ^locked_session.id,
            select: max(turn.turn_sequence)
        ) || 0

      turn =
        %CodexTurn{
          codex_session_id: locked_session.id,
          request_id: request.id,
          turn_sequence: sequence + 1,
          transport_kind: codex_turn_transport_kind(request.transport),
          status: @turn_in_progress,
          started_at: now,
          created_at: now,
          updated_at: now
        }
        |> Repo.insert!()

      case Map.get(opts, :pool_upstream_assignment_id) do
        assignment_id when is_binary(assignment_id) ->
          locked_session
          |> Ecto.Changeset.change(%{
            pool_upstream_assignment_id: assignment_id,
            status: @session_active,
            last_heartbeat_at: now,
            updated_at: now
          })
          |> Repo.update!()

        _value ->
          locked_session
      end

      turn
    end)
    |> unwrap_transaction()
  end

  @spec complete_codex_turn(
          {:ok, %{required(:request) => Request.t(), optional(:attempt) => Attempt.t() | nil}}
          | term(),
          String.t(),
          term()
        ) :: term()
  def complete_codex_turn(
        {:ok, %{request: request} = lifecycle_result} = result,
        status,
        error_code
      ) do
    now = now()
    attempt = Map.get(lifecycle_result, :attempt)

    CodexTurn
    |> Repo.get_by(request_id: request.id)
    |> finalize_codex_turn_state(status, error_code, attempt, now)

    result
  end

  def complete_codex_turn(result, _status, _error_code), do: result

  @spec mark_codex_turn_visible(request_ref()) :: :ok
  def mark_codex_turn_visible(%Request{id: request_id}), do: mark_codex_turn_visible(request_id)

  def mark_codex_turn_visible(request_id) when is_binary(request_id) do
    now = now()

    CodexTurn
    |> where([turn], turn.request_id == ^request_id and is_nil(turn.first_visible_output_at))
    |> Repo.update_all(set: [first_visible_output_at: now, updated_at: now])

    :ok
  end

  def mark_codex_turn_visible(_request_id), do: :ok

  defp turn_opts(%RequestOptions{continuity: continuity, file_bridge: file_bridge}) do
    %{
      codex_turn_id: continuity.codex_turn_id,
      pool_upstream_assignment_id: file_bridge.pool_upstream_assignment_id
    }
    |> drop_nil_values()
  end

  defp ensure_codex_turn_is_unique!(%CodexSession{} = session, opts) do
    case opts |> Map.get(:codex_turn_id) |> blank_to_nil() do
      nil ->
        :ok

      turn_id ->
        case duplicate_codex_turn?(session, turn_id) do
          true ->
            Repo.rollback(%{
              status: 409,
              code: "duplicate_turn",
              message: "duplicate Codex turn was already recorded for this session",
              param: "request_id"
            })

          false ->
            :ok
        end
    end
  end

  defp codex_turn_transport_kind("http_compact_json"), do: "http_json"
  defp codex_turn_transport_kind(transport), do: transport

  defp finalize_codex_turn_state(
         %CodexTurn{status: current_status} = turn,
         target_status,
         error_code,
         attempt,
         now
       )
       when current_status == @turn_in_progress do
    turn
    |> Ecto.Changeset.change(%{
      status: target_status,
      error_code: error_code && to_string(error_code),
      final_attempt_id: attempt && attempt.id,
      first_visible_output_at:
        turn.first_visible_output_at || if(target_status == @turn_succeeded, do: now),
      completed_at: now,
      updated_at: now
    })
    |> Repo.update!()

    maybe_update_session_assignment(turn.codex_session_id, attempt, now)
  end

  defp finalize_codex_turn_state(
         %CodexTurn{status: status} = turn,
         succeeded_status,
         _error_code,
         attempt,
         now
       )
       when status == @turn_interrupted and succeeded_status == @turn_succeeded do
    turn
    |> Ecto.Changeset.change(%{
      status: @turn_succeeded,
      error_code: nil,
      final_attempt_id: attempt && attempt.id,
      first_visible_output_at: turn.first_visible_output_at || now,
      completed_at: now,
      updated_at: now
    })
    |> Repo.update!()

    maybe_update_session_assignment(turn.codex_session_id, attempt, now)
  end

  defp finalize_codex_turn_state(%CodexTurn{} = turn, _status, _error_code, attempt, now) do
    maybe_update_session_assignment(turn.codex_session_id, attempt, now)
  end

  defp finalize_codex_turn_state(nil, _status, _error_code, _attempt, _now), do: :ok

  defp maybe_update_session_assignment(_session_id, nil, _now), do: :ok

  defp maybe_update_session_assignment(session_id, %Attempt{} = attempt, now) do
    CodexSession
    |> where([session], session.id == ^session_id)
    |> Repo.update_all(
      set: [
        pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
        last_heartbeat_at: now,
        updated_at: now
      ]
    )

    BridgeOwnerLease
    |> where(
      [lease],
      lease.codex_session_id == ^session_id and lease.status == ^@owner_lease_active
    )
    |> Repo.update_all(
      set: [
        pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
        renewed_at: now,
        updated_at: now
      ]
    )

    :ok
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp drop_nil_values(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
