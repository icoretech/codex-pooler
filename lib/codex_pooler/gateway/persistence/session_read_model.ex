defmodule CodexPooler.Gateway.Persistence.SessionReadModel do
  @moduledoc """
  Admin-facing read model for persisted Codex session and turn state.
  """

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Request}

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    RuntimeCleanup
  }

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @owner_lease_active BridgeOwnerLease.active_status()
  @session_active CodexSession.active_status()
  @session_alias_active BridgeSessionAlias.active_status()

  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type session_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:status) => String.t(),
          optional(atom()) => term()
        }
  @type turn_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:status) => String.t(),
          optional(atom()) => term()
        }
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

  def list_codex_sessions(pool_or_id, opts \\ [])

  @spec list_codex_sessions(pool_ref(), keyword()) :: %{
          required(:items) => [session_row()],
          required(:turns) => [turn_row()],
          required(:total) => non_neg_integer(),
          required(:limit) => pos_integer()
        }
  def list_codex_sessions(pool_or_id, opts) do
    pool_id = id_for(pool_or_id)
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()
    filters = opts |> Keyword.get(:filters, []) |> Map.new()

    if is_binary(pool_id) do
      query =
        from session in CodexSession,
          left_join: key in APIKey,
          on: key.id == session.api_key_id,
          left_join: latest_turn in subquery(latest_turn_query()),
          on: latest_turn.codex_session_id == session.id,
          left_join: request in Request,
          on: request.id == latest_turn.request_id,
          left_join: attempt in subquery(latest_attempt_query()),
          on: attempt.request_id == request.id,
          where: session.pool_id == ^pool_id

      query = apply_session_filters(query, filters)
      total = Repo.aggregate(query, :count, :id)

      items =
        Repo.all(
          from [session, key, latest_turn, request, attempt] in query,
            order_by: [desc: session.updated_at, desc: session.created_at],
            limit: ^limit,
            select: {session, key, latest_turn, request, attempt}
        )
        |> Enum.map(&session_row/1)

      %{
        items: items,
        turns: list_codex_turns_for_sessions(Enum.map(items, & &1.id)),
        total: total,
        limit: limit
      }
    else
      %{items: [], turns: [], total: 0, limit: limit}
    end
  end

  @spec list_codex_turns_for_sessions([Ecto.UUID.t()]) :: [turn_row()]
  def list_codex_turns_for_sessions([]), do: []

  def list_codex_turns_for_sessions(session_ids) when is_list(session_ids) do
    Repo.all(
      from turn in CodexTurn,
        join: request in Request,
        on: request.id == turn.request_id,
        left_join: attempt in subquery(latest_attempt_query()),
        on: attempt.request_id == request.id,
        where: turn.codex_session_id in ^session_ids,
        order_by: [desc: turn.started_at, desc: turn.turn_sequence],
        select: {turn, request, attempt}
    )
    |> Enum.map(&turn_row/1)
  end

  def list_codex_turns_for_sessions(_session_ids), do: []

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
      Repo.all(
        from turn in CodexTurn,
          join: request in Request,
          on: request.id == turn.request_id,
          where:
            request.pool_id in ^pool_ids and turn.started_at >= ^started_at and
              turn.started_at <= ^ended_at,
          order_by: [desc: turn.started_at],
          select: %{status: turn.status}
      )
    end
  end

  def turn_statuses_for_pool_ids(_pool_ids, _started_at, _ended_at), do: []

  @spec active_runtime_request?(Request.t() | Ecto.UUID.t(), DateTime.t()) :: boolean()
  def active_runtime_request?(request_ref, %DateTime{} = now) do
    RuntimeCleanup.active_runtime_request?(request_ref, now)
  end

  # Reason: session row projection flattens persisted gateway state for admin reads.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp session_row({session, key, latest_turn, request, attempt}) do
    %{
      id: session.id,
      pool_id: session.pool_id,
      api_key_id: session.api_key_id,
      api_key_display_name: key && key.display_name,
      api_key_prefix: key && key.key_prefix,
      session_key: session.session_key,
      conversation_key: session.conversation_key,
      pool_upstream_assignment_id:
        session.pool_upstream_assignment_id || (attempt && attempt.pool_upstream_assignment_id),
      upstream_identity_id: attempt && attempt.upstream_identity_id,
      requested_model: request && request.requested_model,
      status: session.status,
      latest_turn_status: latest_turn && latest_turn.status,
      latest_request_id: request && request.id,
      latest_request_status: request && request.status,
      latest_error_code:
        (latest_turn && latest_turn.error_code) || (request && request.last_error_code) ||
          (attempt && attempt.network_error_code),
      owner_instance_id: session.owner_instance_id,
      owner_lease_expires_at: session.owner_lease_expires_at,
      owner_lease_status: active_owner_lease_status(session.id),
      active_alias_count: active_session_alias_count(session.id),
      last_heartbeat_at: session.last_heartbeat_at,
      disconnected_at: session.disconnected_at,
      closed_at: session.closed_at,
      created_at: session.created_at,
      updated_at: session.updated_at
    }
  end

  defp active_owner_lease_status(session_id) do
    Repo.one(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == ^@owner_lease_active,
        order_by: [desc: lease.renewed_at, desc: lease.created_at],
        limit: 1,
        select: lease.status
    ) || "not recorded"
  end

  defp active_session_alias_count(session_id) do
    Repo.aggregate(
      from(alias_record in BridgeSessionAlias,
        where:
          alias_record.codex_session_id == ^session_id and
            alias_record.status == ^@session_alias_active
      ),
      :count,
      :id
    )
  end

  defp turn_row({turn, request, attempt}) do
    %{
      id: turn.id,
      pool_id: request.pool_id,
      codex_session_id: turn.codex_session_id,
      request_id: turn.request_id,
      turn_sequence: turn.turn_sequence,
      transport_kind: turn.transport_kind,
      status: turn.status,
      error_code:
        turn.error_code || request.last_error_code || (attempt && attempt.network_error_code),
      final_attempt_id: turn.final_attempt_id,
      requested_model: request.requested_model,
      request_status: request.status,
      upstream_identity_id: attempt && attempt.upstream_identity_id,
      pool_upstream_assignment_id: attempt && attempt.pool_upstream_assignment_id,
      response_status_code: request.response_status_code,
      started_at: turn.started_at,
      first_visible_output_at: turn.first_visible_output_at,
      completed_at: turn.completed_at
    }
  end

  defp latest_turn_query do
    from turn in CodexTurn,
      distinct: turn.codex_session_id,
      order_by: [asc: turn.codex_session_id, desc: turn.turn_sequence],
      select: %{
        codex_session_id: turn.codex_session_id,
        request_id: turn.request_id,
        status: turn.status,
        error_code: turn.error_code
      }
  end

  defp latest_attempt_query do
    from attempt in Attempt,
      distinct: attempt.request_id,
      order_by: [asc: attempt.request_id, desc: attempt.attempt_number],
      select: %{
        request_id: attempt.request_id,
        pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
        upstream_identity_id: attempt.upstream_identity_id,
        network_error_code: attempt.network_error_code
      }
  end

  defp apply_session_filters(query, filters) do
    query
    |> maybe_filter_session_api_key(Map.get(filters, :api_key_id))
    |> maybe_filter_session_upstream(Map.get(filters, :upstream_identity_id))
    |> maybe_filter_session_model(Map.get(filters, :model))
    |> maybe_filter_session_status(Map.get(filters, :status))
    |> maybe_filter_session_date_from(Map.get(filters, :date_from))
    |> maybe_filter_session_date_to(Map.get(filters, :date_to))
  end

  defp maybe_filter_session_api_key(query, nil), do: query

  defp maybe_filter_session_api_key(query, api_key_id),
    do: from([s, ...] in query, where: s.api_key_id == ^api_key_id)

  defp maybe_filter_session_upstream(query, nil), do: query

  defp maybe_filter_session_upstream(query, upstream_identity_id) do
    from([_session, _key, _turn, _request, attempt] in query,
      where: attempt.upstream_identity_id == ^upstream_identity_id
    )
  end

  defp maybe_filter_session_model(query, nil), do: query

  defp maybe_filter_session_model(query, model) do
    pattern = "%#{model}%"

    from([_session, _key, _turn, request, _attempt] in query,
      where: ilike(request.requested_model, ^pattern)
    )
  end

  defp maybe_filter_session_status(query, nil), do: query

  defp maybe_filter_session_status(query, status) do
    from([session, _key, turn, request, _attempt] in query,
      where: session.status == ^status or turn.status == ^status or request.status == ^status
    )
  end

  defp maybe_filter_session_date_from(query, nil), do: query

  defp maybe_filter_session_date_from(query, date_from),
    do: from([s, ...] in query, where: s.created_at >= ^date_from)

  defp maybe_filter_session_date_to(query, nil), do: query

  defp maybe_filter_session_date_to(query, date_to),
    do: from([s, ...] in query, where: s.created_at <= ^date_to)

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

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_value), do: nil

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(100)
  defp clamp_limit(_limit), do: 50
end
