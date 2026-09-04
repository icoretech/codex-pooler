defmodule CodexPooler.Gateway.Persistence.SessionContinuity.TurnLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession,
    CodexTurn
  }

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.OwnerLease, as: OwnerLeaseStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Turn, as: TurnStatus
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL

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

      turn = insert_next_codex_turn!(locked_session, request, opts, now)

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

  @doc false
  @spec lock_codex_session_for_turn(CodexSession.t()) :: CodexSession.t()
  def lock_codex_session_for_turn(%CodexSession{id: session_id}) do
    codex_session_for_update!(session_id)
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
    attempt = Map.get(lifecycle_result, :attempt)

    complete_codex_turn_atomic(request.id, attempt, status, error_code)

    result
  end

  def complete_codex_turn(result, _status, _error_code), do: result

  @spec complete_codex_turn(term(), String.t(), term(), Attempt.t()) :: term()
  def complete_codex_turn(
        {:ok, %{request: request}} = result,
        status,
        error_code,
        %Attempt{} = attempt
      ) do
    complete_codex_turn_atomic(request.id, attempt, status, error_code)

    result
  end

  def complete_codex_turn(result, _status, _error_code, %Attempt{}), do: result

  @spec mark_codex_turn_visible(request_ref()) :: :ok
  def mark_codex_turn_visible(%Request{id: request_id}), do: mark_codex_turn_visible(request_id)

  def mark_codex_turn_visible(request_id) when is_binary(request_id) do
    now = lifecycle_now(request_id, nil)

    CodexTurn
    |> where(
      [turn],
      turn.request_id == ^request_id and is_nil(turn.first_visible_output_at) and
        fragment(
          "NOT EXISTS (SELECT 1 FROM request_replay_entitlements e WHERE e.request_id = ?)",
          turn.request_id
        )
    )
    |> Repo.update_all(set: [first_visible_output_at: now, updated_at: now])

    :ok
  end

  def mark_codex_turn_visible(_request_id), do: :ok

  @spec mark_codex_turn_visible(request_ref(), CodexPooler.Accounting.Attempt.t()) ::
          :ok | {:error, :stale_generation}
  def mark_codex_turn_visible(%Request{id: request_id}, attempt),
    do: mark_codex_turn_visible(request_id, attempt)

  def mark_codex_turn_visible(request_id, %{
        id: attempt_id,
        request_id: request_id,
        replay_generation: generation
      })
      when is_binary(request_id) and is_binary(attempt_id) and is_integer(generation) do
    case authorize_codex_turn_visibility(request_id, %{
           id: attempt_id,
           request_id: request_id,
           replay_generation: generation
         }) do
      {:ok, _visibility} -> :ok
      {:error, :stale_generation} = error -> error
    end
  end

  def mark_codex_turn_visible(_request_id, _attempt), do: {:error, :stale_generation}

  @type visibility_witness :: :committed | :uncommitted | :untracked

  @spec authorize_codex_turn_visibility(request_ref(), map()) ::
          {:ok, visibility_witness()} | {:error, :stale_generation}
  def authorize_codex_turn_visibility(%Request{id: request_id}, attempt),
    do: authorize_codex_turn_visibility(request_id, attempt)

  def authorize_codex_turn_visibility(request_id, %{
        id: attempt_id,
        request_id: request_id,
        replay_generation: generation
      })
      when is_binary(request_id) and is_binary(attempt_id) and is_integer(generation) do
    nested? = Repo.in_transaction?()

    {:ok, result} =
      Repo.transaction(fn ->
        # Arm locks this row without updating it. A single UPDATE with joined
        # eligibility checks can otherwise retain its pre-wait MVCC snapshot.
        turn =
          Repo.one(
            from turn in CodexTurn,
              where: turn.request_id == ^request_id,
              lock: "FOR UPDATE"
          )

        case mark_locked_turn_visible(turn, request_id, attempt_id, generation) do
          :visible -> {:ok, if(nested?, do: :uncommitted, else: :committed)}
          :untracked -> {:ok, :untracked}
          {:error, :stale_generation} = error -> error
        end
      end)

    result
  end

  def authorize_codex_turn_visibility(_request, _attempt), do: {:error, :stale_generation}

  defp mark_locked_turn_visible(nil, request_id, _attempt_id, _generation) do
    mark_codex_turn_visible(request_id)
    :untracked
  end

  defp mark_locked_turn_visible(%CodexTurn{}, request_id, attempt_id, generation) do
    now = lifecycle_now(request_id, %{replay_generation: generation})

    {count, _rows} =
      CodexTurn
      |> join(:inner, [turn], attempt in CodexPooler.Accounting.Attempt,
        on: attempt.id == ^attempt_id and attempt.request_id == turn.request_id
      )
      |> where(
        [turn, attempt],
        turn.request_id == ^request_id and
          attempt.replay_generation == ^generation and attempt.status == "in_progress" and
          fragment(
            "NOT EXISTS (SELECT 1 FROM request_replay_entitlements e WHERE e.request_id = ? AND e.replay_generation <> ?)",
            turn.request_id,
            ^generation
          ) and
          is_nil(turn.first_visible_output_at)
      )
      |> Repo.update_all(set: [first_visible_output_at: now, updated_at: now])

    visibility_update_result(count, request_id, attempt_id, generation)
  end

  defp visibility_update_result(count, request_id, attempt_id, generation) do
    cond do
      count == 1 or visible_attempt_current?(request_id, attempt_id, generation) ->
        :visible

      replay_entitlement?(request_id) ->
        {:error, :stale_generation}

      true ->
        mark_codex_turn_visible(request_id)
        :untracked
    end
  end

  defp visible_attempt_current?(request_id, attempt_id, generation) do
    Repo.exists?(
      from turn in CodexTurn,
        join: attempt in CodexPooler.Accounting.Attempt,
        on: attempt.id == ^attempt_id and attempt.request_id == turn.request_id,
        where:
          turn.request_id == ^request_id and not is_nil(turn.first_visible_output_at) and
            attempt.replay_generation == ^generation and attempt.status == "in_progress" and
            fragment(
              "NOT EXISTS (SELECT 1 FROM request_replay_entitlements e WHERE e.request_id = ? AND e.replay_generation <> ?)",
              turn.request_id,
              ^generation
            )
    )
  end

  defp replay_entitlement?(request_id) do
    Repo.exists?(
      from entitlement in RequestReplayEntitlement,
        where: entitlement.request_id == ^request_id
    )
  end

  defp complete_codex_turn_atomic(request_id, nil, status, error_code) do
    now = lifecycle_now(request_id, nil)

    request_id
    |> legacy_completion_query(status)
    |> update_completion(status, error_code, nil, now)

    :ok
  end

  defp complete_codex_turn_atomic(
         request_id,
         %Attempt{id: attempt_id, replay_generation: generation} = attempt,
         status,
         error_code
       ) do
    now = lifecycle_now(request_id, attempt)

    {count, _rows} =
      request_id
      |> generation_completion_query(attempt_id, generation, status)
      |> update_completion(status, error_code, attempt_id, now)

    if count == 1 do
      turn = Repo.get_by!(CodexTurn, request_id: request_id)
      maybe_update_session_assignment(turn.codex_session_id, attempt, now)
    end

    :ok
  end

  defp legacy_completion_query(request_id, status) do
    CodexTurn
    |> where(
      [turn],
      turn.request_id == ^request_id and
        fragment(
          "NOT EXISTS (SELECT 1 FROM request_replay_entitlements e WHERE e.request_id = ?)",
          turn.request_id
        ) and
        (turn.status == ^@turn_in_progress or
           (turn.status == ^@turn_interrupted and ^status == ^@turn_succeeded))
    )
  end

  defp generation_completion_query(request_id, attempt_id, generation, status) do
    CodexTurn
    |> join(:inner, [turn], attempt in Attempt,
      on: attempt.id == ^attempt_id and attempt.request_id == turn.request_id
    )
    |> where(
      [turn, attempt],
      turn.request_id == ^request_id and attempt.replay_generation == ^generation and
        fragment(
          "NOT EXISTS (SELECT 1 FROM request_replay_entitlements e WHERE e.request_id = ? AND e.replay_generation <> ?)",
          turn.request_id,
          ^generation
        ) and
        (turn.status == ^@turn_in_progress or
           (turn.status == ^@turn_interrupted and ^status == ^@turn_succeeded))
    )
  end

  defp update_completion(query, status, _error_code, attempt_id, now)
       when status == @turn_succeeded do
    query
    |> update([turn],
      set: [
        status: ^status,
        error_code: nil,
        final_attempt_id: ^attempt_id,
        first_visible_output_at: fragment("COALESCE(?, ?)", turn.first_visible_output_at, ^now),
        completed_at: ^now,
        updated_at: ^now
      ]
    )
    |> Repo.update_all([])
  end

  defp update_completion(query, status, error_code, attempt_id, now) do
    query
    |> Repo.update_all(
      set: [
        status: status,
        error_code: error_code && to_string(error_code),
        final_attempt_id: attempt_id,
        completed_at: now,
        updated_at: now
      ]
    )
  end

  @spec codex_session_for_update!(Ecto.UUID.t()) :: CodexSession.t()
  defp codex_session_for_update!(session_id) do
    Repo.one!(
      from session in CodexSession,
        where: session.id == ^session_id,
        lock: "FOR UPDATE"
    )
  end

  defp insert_next_codex_turn!(%CodexSession{} = session, %Request{} = request, opts, now) do
    query = """
    INSERT INTO codex_turns (
      id,
      codex_session_id,
      request_id,
      turn_sequence,
      transport_kind,
      semantic_turn_digest,
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
      $7,
      $7,
      $7
    FROM codex_turns
    WHERE codex_session_id = $2::uuid
    RETURNING *
    """

    params = [
      Ecto.UUID.generate() |> Ecto.UUID.dump!(),
      Ecto.UUID.dump!(session.id),
      Ecto.UUID.dump!(request.id),
      codex_turn_transport_kind(request.transport),
      Map.get(opts, :semantic_turn_digest),
      @turn_in_progress,
      now
    ]

    %{columns: columns, rows: [row]} = SQL.query!(Repo, query, params)
    Repo.load(CodexTurn, {columns, row})
  end

  defp turn_opts(%RequestOptions{continuity: continuity, file_bridge: file_bridge}) do
    %{
      turn_claim_key: continuity.turn_claim_key,
      semantic_turn_digest: continuity.semantic_turn_key,
      pool_upstream_assignment_id: file_bridge.pool_upstream_assignment_id
    }
    |> drop_nil_values()
  end

  defp codex_turn_transport_kind("http_compact_json"), do: "http_json"
  defp codex_turn_transport_kind(transport), do: transport

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

  defp lifecycle_now(request_id, %{replay_generation: generation}) when generation > 0,
    do: replay_db_now(request_id)

  defp lifecycle_now(request_id, nil) do
    if Repo.exists?(
         from replay in RequestReplayEntitlement, where: replay.request_id == ^request_id
       ),
       do: replay_db_now(request_id),
       else: now()
  end

  defp lifecycle_now(_request_id, _attempt), do: now()

  defp replay_db_now(request_id) do
    Repo.one!(
      from turn in CodexTurn,
        where: turn.request_id == ^request_id,
        limit: 1,
        select: type(fragment("request_replay_db_now()"), :utc_datetime_usec)
    )
  end

  defp drop_nil_values(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
