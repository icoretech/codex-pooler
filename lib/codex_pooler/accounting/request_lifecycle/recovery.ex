defmodule CodexPooler.Accounting.RequestLifecycle.Recovery do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestLifecycle
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup
  alias CodexPooler.Repo

  @stale_after_seconds 6 * 60 * 60
  @request_statuses ~w(accepted in_progress)
  @attempt_statuses ~w(queued in_progress retryable_failed failed cancelled)
  @recovery_code "stale_reservation_recovered"
  @recovery_source "stale_reservation_recovery"

  @spec recover_stale_reservations(DateTime.t(), keyword()) ::
          {:ok,
           %{
             required(:stale_reservations_released) => non_neg_integer(),
             required(:stale_reservations_settled) => non_neg_integer()
           }}
          | {:error, term()}
  def recover_stale_reservations(now, opts \\ []) do
    cutoff =
      DateTime.add(now, -Keyword.get(opts, :stale_after_seconds, @stale_after_seconds), :second)

    limit = Keyword.get(opts, :limit, 100)

    now
    |> stale_requests(cutoff, limit)
    |> Enum.reduce_while({:ok, initial_summary()}, &recover_request(&1, &2, now))
  end

  defp stale_requests(now, cutoff, limit) do
    Repo.all(
      from request in Request,
        join: reservation in LedgerEntry,
        on:
          reservation.request_id == request.id and reservation.entry_kind == "reservation" and
            reservation.amount_status == "recorded",
        left_join: release in LedgerEntry,
        on: release.request_id == request.id and release.entry_kind == "release",
        where:
          request.status in ^@request_statuses and request.admitted_at <= ^cutoff and
            is_nil(release.id),
        order_by: [asc: request.admitted_at, asc: request.id],
        limit: ^limit,
        select: request
    )
    |> Enum.reject(&RuntimeCleanup.active_runtime_request?(&1, now))
  end

  defp recover_request(request, {:ok, summary}, now) do
    case latest_attempt(request.id) do
      nil ->
        case release_undispatched_request(request, now) do
          {:ok, _result} -> {:cont, {:ok, increment(summary, :stale_reservations_released)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      %Attempt{} = attempt ->
        case settle_dispatched_request(request, attempt, now) do
          {:ok, _result} -> {:cont, {:ok, increment(summary, :stale_reservations_settled)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp latest_attempt(request_id) do
    Repo.one(
      from attempt in Attempt,
        where: attempt.request_id == ^request_id and attempt.status in ^@attempt_statuses,
        order_by: [desc: attempt.attempt_number],
        limit: 1
    )
  end

  defp release_undispatched_request(%Request{} = request, now) do
    with {:ok, result} <-
           RequestLifecycle.finalize_reserved_request_failure(request, %{
             request_status: "failed",
             response_status_code: 499,
             last_error_code: @recovery_code,
             usage_status: "not_applicable",
             now: now
           }) do
      recover_stale_turn(request, nil, now)
      {:ok, result}
    end
  end

  defp settle_dispatched_request(%Request{} = request, %Attempt{} = attempt, now) do
    with {:ok, result} <-
           RequestLifecycle.finalize_request(request, attempt, %{
             request_status: "failed",
             attempt_status: "failed",
             response_status_code: 499,
             last_error_code: @recovery_code,
             error_message: "stale reservation recovered after request lifecycle was abandoned",
             usage: %{status: "usage_unknown", source: @recovery_source},
             now: now
           }) do
      recover_stale_turn(request, attempt, now)
      {:ok, result}
    end
  end

  defp recover_stale_turn(%Request{id: request_id}, attempt, now) when is_binary(request_id) do
    RuntimeCleanup.recover_stale_request_turn(request_id, attempt_id(attempt),
      now: now,
      error_code: @recovery_code
    )
  end

  defp recover_stale_turn(%Request{}, _attempt, _now), do: :ok

  defp attempt_id(%Attempt{id: attempt_id}) when is_binary(attempt_id), do: attempt_id
  defp attempt_id(_attempt), do: nil

  defp initial_summary do
    %{stale_reservations_released: 0, stale_reservations_settled: 0}
  end

  defp increment(summary, key), do: Map.update!(summary, key, &(&1 + 1))
end
