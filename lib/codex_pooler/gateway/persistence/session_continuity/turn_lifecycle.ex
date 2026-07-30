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
  alias Ecto.Adapters.SQL
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.OwnerLease, as: OwnerLeaseStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Turn, as: TurnStatus

  @type turn_result :: {:ok, CodexTurn.t()} | {:error, term()}
  @type request_ref :: Request.t() | Ecto.UUID.t()
  @type opts :: RequestOptions.t()

  @turn_in_progress TurnStatus.in_progress_status()
  @turn_succeeded TurnStatus.succeeded_status()
  @turn_interrupted TurnStatus.interrupted_status()
  @session_active SessionStatus.active_status()
  @owner_lease_active OwnerLeaseStatus.active_status()

  @spec start_codex_turn(CodexSession.t(), Request.t(), opts()) :: turn_result()
  def start_codex_turn(
        %CodexSession{} = session,
        %Request{} = request,
        %RequestOptions{} = opts
      ) do
    now = now()
    opts = turn_opts(opts)

    Repo.transaction(fn ->
      locked_session = codex_session_for_update!(session.id)

      turn = insert_next_codex_turn!(locked_session, request, now)

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

  @spec codex_session_for_update!(Ecto.UUID.t()) :: CodexSession.t()
  defp codex_session_for_update!(session_id) do
    Repo.one!(
      from session in CodexSession,
        where: session.id == ^session_id,
        lock: "FOR UPDATE"
    )
  end

  defp insert_next_codex_turn!(%CodexSession{} = session, %Request{} = request, now) do
    query = """
    INSERT INTO codex_turns (
      id,
      codex_session_id,
      request_id,
      turn_sequence,
      transport_kind,
      status,
      started_at,
      created_at,
      updated_at
    )
    SELECT
      $1::uuid,
      $2::uuid,
      $3::uuid,
      COALESCE(MAX(turn_sequence), 0) + 1,
      $4,
      $5,
      $6,
      $6,
      $6
    FROM codex_turns
    WHERE codex_session_id = $2::uuid
    RETURNING *
    """

    params = [
      Ecto.UUID.generate() |> Ecto.UUID.dump!(),
      Ecto.UUID.dump!(session.id),
      Ecto.UUID.dump!(request.id),
      codex_turn_transport_kind(request.transport),
      @turn_in_progress,
      now
    ]

    %{columns: columns, rows: [row]} = SQL.query!(Repo, query, params)
    Repo.load(CodexTurn, {columns, row})
  end

  defp turn_opts(%RequestOptions{continuity: continuity, file_bridge: file_bridge}) do
    %{
      codex_turn_id: continuity.codex_turn_id,
      pool_upstream_assignment_id: file_bridge.pool_upstream_assignment_id
    }
    |> drop_nil_values()
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp drop_nil_values(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
