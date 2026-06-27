defmodule CodexPooler.Admin.GatewayReadModel do
  @moduledoc """
  Read-only gateway projections for admin/reporting surfaces.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Persistence.SessionReadModel
  alias CodexPooler.Repo

  @type bucket_granularity :: :hour | :day

  @spec requests_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [map()]
  def requests_for_pool_ids([], _started_at, _ended_at), do: []

  def requests_for_pool_ids(pool_ids, started_at, ended_at) do
    Repo.all(
      from request in Request,
        where:
          request.pool_id in ^pool_ids and request.admitted_at >= ^started_at and
            request.admitted_at <= ^ended_at,
        order_by: [desc: request.admitted_at, desc: request.id],
        select: %{
          id: request.id,
          pool_id: request.pool_id,
          requested_model: request.requested_model,
          endpoint: request.endpoint,
          transport: request.transport,
          status: request.status,
          last_error_code: request.last_error_code,
          response_status_code: request.response_status_code,
          admitted_at: request.admitted_at
        }
    )
  end

  @spec request_counts_by_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  def request_counts_by_pool_ids([], _started_at, _ended_at), do: %{}

  def request_counts_by_pool_ids(pool_ids, started_at, ended_at) do
    Repo.all(
      from request in Request,
        where:
          request.pool_id in ^pool_ids and request.admitted_at >= ^started_at and
            request.admitted_at <= ^ended_at,
        group_by: request.pool_id,
        select: {request.pool_id, count(request.id)}
    )
    |> Map.new()
  end

  @spec hourly_request_counts_by_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [
          %{
            required(:pool_id) => Ecto.UUID.t(),
            required(:bucket) => DateTime.t(),
            required(:requests) => non_neg_integer()
          }
        ]
  def hourly_request_counts_by_pool_ids([], _started_at, _ended_at), do: []

  def hourly_request_counts_by_pool_ids(pool_ids, started_at, ended_at) do
    bucketed_request_counts_by_pool_ids(pool_ids, started_at, ended_at, :hour)
  end

  @spec bucketed_request_counts_by_pool_ids(
          [Ecto.UUID.t()],
          DateTime.t(),
          DateTime.t(),
          bucket_granularity()
        ) :: [
          %{
            required(:pool_id) => Ecto.UUID.t(),
            required(:bucket) => DateTime.t(),
            required(:requests) => non_neg_integer()
          }
        ]
  def bucketed_request_counts_by_pool_ids([], _started_at, _ended_at, _granularity), do: []

  def bucketed_request_counts_by_pool_ids(pool_ids, started_at, ended_at, :hour) do
    Repo.all(
      from request in Request,
        where:
          request.pool_id in ^pool_ids and request.admitted_at >= ^started_at and
            request.admitted_at <= ^ended_at,
        group_by: [request.pool_id, fragment("date_trunc('hour', ?)", request.admitted_at)],
        order_by: [asc: fragment("date_trunc('hour', ?)", request.admitted_at)],
        select: %{
          pool_id: request.pool_id,
          bucket:
            type(fragment("date_trunc('hour', ?)", request.admitted_at), :utc_datetime_usec),
          requests: count(request.id)
        }
    )
  end

  def bucketed_request_counts_by_pool_ids(pool_ids, started_at, ended_at, :day) do
    Repo.all(
      from request in Request,
        where:
          request.pool_id in ^pool_ids and request.admitted_at >= ^started_at and
            request.admitted_at <= ^ended_at,
        group_by: [request.pool_id, fragment("date_trunc('day', ?)", request.admitted_at)],
        order_by: [asc: fragment("date_trunc('day', ?)", request.admitted_at)],
        select: %{
          pool_id: request.pool_id,
          bucket: type(fragment("date_trunc('day', ?)", request.admitted_at), :utc_datetime_usec),
          requests: count(request.id)
        }
    )
  end

  @spec attempts_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [map()]
  def attempts_for_pool_ids([], _started_at, _ended_at), do: []

  def attempts_for_pool_ids(pool_ids, started_at, ended_at) do
    Repo.all(
      from attempt in Attempt,
        join: request in Request,
        on: request.id == attempt.request_id,
        where:
          request.pool_id in ^pool_ids and attempt.started_at >= ^started_at and
            attempt.started_at <= ^ended_at,
        order_by: [desc: attempt.started_at],
        select: %{latency_ms: attempt.latency_ms}
    )
  end

  @spec latency_totals_by_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  def latency_totals_by_pool_ids([], _started_at, _ended_at), do: %{}

  def latency_totals_by_pool_ids(pool_ids, started_at, ended_at) do
    Repo.all(
      from attempt in Attempt,
        join: request in Request,
        on: request.id == attempt.request_id,
        where:
          request.pool_id in ^pool_ids and attempt.started_at >= ^started_at and
            attempt.started_at <= ^ended_at and not is_nil(attempt.latency_ms),
        group_by: request.pool_id,
        select: {request.pool_id, sum(attempt.latency_ms)}
    )
    |> Map.new(fn {pool_id, total} -> {pool_id, non_negative_integer(total)} end)
  end

  @spec active_session_count_for_pool_ids([Ecto.UUID.t()]) :: non_neg_integer()
  def active_session_count_for_pool_ids([]), do: 0

  def active_session_count_for_pool_ids(pool_ids) do
    SessionReadModel.active_session_count_for_pool_ids(pool_ids)
  end

  @spec turns_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [map()]
  def turns_for_pool_ids([], _started_at, _ended_at), do: []

  def turns_for_pool_ids(pool_ids, started_at, ended_at) do
    SessionReadModel.turn_statuses_for_pool_ids(pool_ids, started_at, ended_at)
  end

  defp non_negative_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp non_negative_integer(value) when is_integer(value), do: max(value, 0)
  defp non_negative_integer(value) when is_float(value), do: max(round(value), 0)
  defp non_negative_integer(_value), do: 0
end
