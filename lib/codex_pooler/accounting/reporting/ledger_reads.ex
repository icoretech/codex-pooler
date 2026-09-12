defmodule CodexPooler.Accounting.LedgerReads do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Repo

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
        where:
          attempt.pool_upstream_assignment_id in ^assignment_ids and attempt.status == "succeeded",
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
