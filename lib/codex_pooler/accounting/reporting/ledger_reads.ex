defmodule CodexPooler.Accounting.LedgerReads do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Repo

  @live_request_statuses ["accepted", "in_progress"]

  # The admission check for `max_active_requests`: the key's requests that are
  # still open and hold a recorded reservation nothing released or settled
  # (findings#206 row 206-461). It reads the key's open requests only, never
  # its reservation history (747,651 reservations for the largest production
  # key made the old anti join a 577k-cost parallel hash join per admission).
  # A reservation of a finished request cannot be live work: nothing reopens a
  # finished request, and the stale-reservation sweep visits open ones only, so
  # one left unreleased used to hold a cap slot forever. No time bound: an open
  # request past the sweep's six hours (replay-held, still live, or no scheduler
  # node) still holds its slot. The ledger side is one aggregate over the
  # request's own entries: PostgreSQL never pulls an EXISTS with an aggregate up
  # into a join, and only `request_id` is constrained, so with missing or empty
  # planner statistics it stays a probe of `ledger_entries_request_occurred_idx`
  # per open request instead of a scan of the key's reservations.
  @spec outstanding_reservation_count(Ecto.UUID.t()) :: non_neg_integer()
  def outstanding_reservation_count(api_key_id) do
    held =
      from entry in LedgerEntry,
        where: entry.request_id == parent_as(:request).id,
        having:
          filter(count(), entry.entry_kind == "reservation" and entry.amount_status == "recorded") > 0 and
            filter(count(), entry.entry_kind in ["release", "settlement"]) == 0,
        select: 1

    Repo.one!(
      from request in Request,
        as: :request,
        where: request.api_key_id == ^api_key_id and request.status in @live_request_statuses and exists(subquery(held)),
        select: count()
    )
  end

  @spec latest_success_by_assignment_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => DateTime.t() | nil
        }
  def latest_success_by_assignment_ids(assignment_ids) when is_list(assignment_ids) do
    assignment_ids =
      assignment_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.all(
      from attempt in Attempt,
        where: attempt.pool_upstream_assignment_id in ^assignment_ids and attempt.status == "succeeded",
        group_by: attempt.pool_upstream_assignment_id,
        select: {attempt.pool_upstream_assignment_id, max(attempt.completed_at)}
    )
    |> Map.new()
  end

  # A reservation whose reserved budget is still held: recorded, and neither
  # returned by a release nor consumed by a settlement. Callers finalizing a
  # request that never produced an attempt ask this before calling
  # `finalize_reservation_failure/2`, which requires the reservation row to
  # exist and would raise for a request that was rejected before the ledger.
  @spec reservation_outstanding?(Request.t() | Ecto.UUID.t()) :: boolean()
  def reservation_outstanding?(%Request{id: request_id}),
    do: reservation_outstanding?(request_id)

  def reservation_outstanding?(request_id) when is_binary(request_id) do
    Repo.exists?(
      from entry in LedgerEntry,
        where:
          entry.request_id == ^request_id and entry.entry_kind == "reservation" and
            entry.amount_status == "recorded"
    ) and
      not Repo.exists?(
        from entry in LedgerEntry,
          where: entry.request_id == ^request_id and entry.entry_kind in ["release", "settlement"]
      )
  end

  @spec list_ledger_entries_for_request(Request.t() | Ecto.UUID.t()) :: [LedgerEntry.t()]
  def list_ledger_entries_for_request(%Request{id: request_id}),
    do: list_ledger_entries_for_request(request_id)

  def list_ledger_entries_for_request(request_id) when is_binary(request_id) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.request_id == ^request_id,
        order_by: [asc: entry.occurred_at, asc: entry.created_at]
    )
  end
end
