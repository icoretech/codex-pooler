defmodule CodexPooler.Accounting.RequestLifecycle.TurnClaimRelease do
  @moduledoc false

  # A native websocket request takes its request claim (`codex-turn:`,
  # `codex-request:`, `codex-resume:`, or a derived `codex-request-retry:`) in a
  # transaction of its own, before the reservation. The claim is the fence that
  # stops the provider being paid twice for one request: a resend carrying it
  # meets `requests_correlation_id_uq` and only the resend policy
  # (`FailedPredecessorResend`) may chain it onto the row that holds it.
  #
  # A row that never got past its claim -- no ledger entry, no attempt, no turn,
  # no replay entitlement -- sent nothing to the provider, so there is nothing
  # for its claim to protect. Such a row used to keep its claim once it was
  # closed, and each of these closes fenced every resend of the request with a
  # permanent `409 duplicate_turn`, although the runbook says those resends must
  # be served:
  #
  # - a refusal at the reservation (the key's active-request cap "retry
  #   shortly", a token window, no eligible backend), which rewrites the claim
  #   row to `rejected` (findings#206 row 206-420);
  # - the socket's direct interrupt, when the client left between the claim and
  #   the reservation (`failed client_disconnected`, row 206-419);
  # - the six-hour stale-claim recovery (`stale_websocket_turn_claim_recovered`,
  #   row 206-421).
  #
  # Closing such a row now gives its claim up: the row keeps its history under a
  # fresh correlation id, `request_metadata.released_turn_claim` names the claim
  # it held, and its own client-retry link goes, so the predecessor it chained
  # onto (which the resend policy refuses while a link names it) can be chained
  # onto again by the next resend, under the same policy checks. A row another
  # request chained onto is never touched, and neither is the owner's
  # pre-attempt drain row, whose claim the drain resend chains from
  # (`ClientRetry.verified_claim_only_drain?/1`); the callers keep that one.

  import Ecto.Query

  require Logger

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo

  @type reason :: :reservation_refused | :client_left_before_reservation | :stale_claim_recovered

  @doc false
  # The row sent nothing anywhere: a websocket request with no ledger entry,
  # attempt, turn or replay entitlement, and no request chained onto it.
  @spec claim_only?(Request.t()) :: boolean()
  def claim_only?(%Request{id: id, transport: "websocket"}) when is_binary(id) do
    not (Repo.exists?(from entry in LedgerEntry, where: entry.request_id == ^id) or
           Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^id) or
           Repo.exists?(from turn in CodexTurn, where: turn.request_id == ^id) or
           Repo.exists?(from entitlement in RequestReplayEntitlement, where: entitlement.request_id == ^id) or
           Repo.exists?(from link in RequestClientRetryLink, where: link.predecessor_request_id == ^id))
  end

  def claim_only?(%Request{}), do: false

  @doc false
  # Applies `changes` (the close) to a row the caller holds `FOR UPDATE` in its
  # transaction and, when the row is still nothing but its claim, gives the
  # claim up with it. Returns the updated row.
  @spec close!(Request.t(), map(), reason()) :: Request.t()
  def close!(%Request{} = request, changes, reason) when is_map(changes) do
    if claim_only?(request) do
      {_links, _returned} = Repo.delete_all(from link in RequestClientRetryLink, where: link.successor_request_id == ^request.id)

      released =
        request
        |> Ecto.Changeset.change(
          changes
          |> Map.put(:correlation_id, Ecto.UUID.generate())
          |> Map.put(:request_metadata, Map.put(Map.get(changes, :request_metadata) || request.request_metadata || %{}, "released_turn_claim", request.correlation_id))
        )
        |> Repo.update!()

      Logger.info("websocket turn claim released request_id=#{request.id} release_reason=#{reason}")
      released
    else
      request
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()
    end
  end
end
