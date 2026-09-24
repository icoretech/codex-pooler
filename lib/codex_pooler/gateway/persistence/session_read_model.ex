defmodule CodexPooler.Gateway.Persistence.SessionReadModel do
  @moduledoc """
  Admin-facing read model for persisted Codex session and turn state.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus
  alias CodexPooler.Repo

  @session_active SessionStatus.active_status()

  @type request_turn_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:codex_session_id) => Ecto.UUID.t(),
          required(:request_id) => Ecto.UUID.t(),
          required(:status) => String.t(),
          required(:error_code) => String.t() | nil,
          required(:final_attempt_id) => Ecto.UUID.t() | nil,
          required(:created_at) => DateTime.t(),
          required(:updated_at) => DateTime.t(),
          required(:completed_at) => DateTime.t() | nil
        }
  @type turn_status_row :: %{required(:status) => String.t()}

  @spec request_turns_by_request_ids([Ecto.UUID.t() | term()]) :: %{
          optional(Ecto.UUID.t()) => request_turn_row()
        }
  def request_turns_by_request_ids(request_ids) when is_list(request_ids) do
    request_ids = valid_uuid_ids(request_ids)

    if request_ids == [] do
      %{}
    else
      Repo.all(
        from turn in CodexTurn,
          where: turn.request_id in ^request_ids,
          select: %{
            id: turn.id,
            codex_session_id: turn.codex_session_id,
            request_id: turn.request_id,
            status: turn.status,
            error_code: turn.error_code,
            final_attempt_id: turn.final_attempt_id,
            created_at: turn.created_at,
            updated_at: turn.updated_at,
            completed_at: turn.completed_at
          }
      )
      |> Map.new(&{&1.request_id, &1})
    end
  end

  def request_turns_by_request_ids(_request_ids), do: %{}

  @spec active_session_count_for_pool_ids([Ecto.UUID.t() | term()]) :: non_neg_integer()
  def active_session_count_for_pool_ids(pool_ids) when is_list(pool_ids) do
    pool_ids = valid_uuid_ids(pool_ids)

    if pool_ids == [] do
      0
    else
      Repo.one(
        from session in CodexSession,
          where: session.pool_id in ^pool_ids and session.status == ^@session_active,
          select: count(session.id)
      ) || 0
    end
  end

  def active_session_count_for_pool_ids(_pool_ids), do: 0

  @spec turn_statuses_for_pool_ids([Ecto.UUID.t() | term()], DateTime.t(), DateTime.t()) :: [
          turn_status_row()
        ]
  def turn_statuses_for_pool_ids(pool_ids, %DateTime{} = started_at, %DateTime{} = ended_at)
      when is_list(pool_ids) do
    pool_ids = valid_uuid_ids(pool_ids)

    if pool_ids == [] do
      []
    else
      # Each window turn probes its own request by primary key. `offset: 0` keeps
      # the probe a per-turn SubPlan: with missing planner statistics a join (or an
      # EXISTS PostgreSQL pulls up into one) became a nested loop that rescanned
      # the Pools' requests for every turn, count^2 rows (findings#206).
      visible_request =
        from request in Request,
          where: request.id == parent_as(:turn).request_id and request.pool_id in ^pool_ids,
          select: 1,
          offset: 0

      Repo.all(
        from turn in CodexTurn,
          as: :turn,
          where: turn.started_at >= ^started_at and turn.started_at <= ^ended_at,
          where: exists(visible_request),
          order_by: [desc: turn.started_at],
          select: %{status: turn.status}
      )
    end
  end

  def turn_statuses_for_pool_ids(_pool_ids, _started_at, _ended_at), do: []

  defp valid_uuid_ids(ids) do
    ids
    |> Enum.flat_map(fn
      id when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end

      _id ->
        []
    end)
    |> Enum.uniq()
  end
end
