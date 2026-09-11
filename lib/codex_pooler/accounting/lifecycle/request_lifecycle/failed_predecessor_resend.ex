defmodule CodexPooler.Accounting.RequestLifecycle.FailedPredecessorResend do
  @moduledoc false

  # A byte-identical Codex websocket resend carries the request claim of the
  # request it repeats. When that request already ended in a terminal failure
  # the claim's uniqueness constraint must not fence the resend until the turn
  # is abandoned, so the claim path resolves the conflicting chain here, inside
  # the transaction that holds the codex session lock, and records the resend
  # under a claim derived from the terminal predecessor. Concurrent resends of
  # the same frame still collapse on that derived claim, and a resend after the
  # retry itself fails chains from the retry request.
  #
  # Every check fails closed: a live request, turn, or attempt, a succeeded or
  # otherwise non-failed predecessor, a failure outside the provider-terminal
  # and task-exception vocabulary (an owner drain or a client disconnect is not
  # a provider verdict), an anchored resend (a `previous_response_id` is bound
  # to the connection that produced it; the released client drops the anchor
  # before it retries), a replay entitlement, a scope mismatch, or an expired
  # retry window keeps the public `duplicate_turn` fence.

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Repo

  @max_chain_depth 16
  @task_exception_code "owner_task_exception"
  @live_request_statuses ["accepted", "in_progress"]
  @live_attempt_statuses ["queued", "in_progress"]

  @type scope :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:model_id) => Ecto.UUID.t(),
          required(:endpoint) => String.t() | nil,
          optional(:anchor_present?) => boolean()
        }

  @type disposition ::
          :unsupported_claim
          | :missing_predecessor
          | :authorization_changed
          | :active_predecessor
          | :terminal_predecessor
          | :entitlement_present
          | :retry_expired
          | :chain_exhausted
          | :invalid_predecessor
          | :anchor_unavailable

  @type resolution :: %{claim: String.t(), predecessor: Request.t()}

  @doc false
  @spec resolve(term(), scope()) :: {:ok, resolution()} | {:error, disposition()}
  def resolve(claim, scope) when is_binary(claim) and is_map(scope) do
    cond do
      not (WebsocketTurnIdentity.request_claim?(claim) or
               ClientRetry.failed_predecessor_claim?(claim)) ->
        {:error, :unsupported_claim}

      Map.get(scope, :anchor_present?) == true ->
        {:error, :anchor_unavailable}

      true ->
        resolve_chain(claim, nil, scope, db_now(), 0)
    end
  end

  def resolve(_claim, _scope), do: {:error, :unsupported_claim}

  defp resolve_chain(_claim, _predecessor, _scope, _now, depth) when depth > @max_chain_depth,
    do: {:error, :chain_exhausted}

  defp resolve_chain(claim, predecessor, scope, now, depth) do
    case lock_request_by_claim(claim) do
      nil when is_nil(predecessor) ->
        {:error, :missing_predecessor}

      nil ->
        {:ok, %{claim: claim, predecessor: predecessor}}

      %Request{} = request ->
        with :ok <- validate_predecessor(request, scope, now),
             {:ok, derived} <-
               ClientRetry.deterministic_failed_predecessor_claim(claim, request.id) do
          resolve_chain(derived, request, scope, now, depth + 1)
        end
    end
  end

  defp lock_request_by_claim(claim) do
    Repo.one(
      from request in Request,
        where: request.correlation_id == ^claim,
        lock: "FOR UPDATE"
    )
  end

  # The explicit conjunction keeps every terminal requirement visible.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_predecessor(%Request{} = request, scope, now) do
    cond do
      not scoped?(request, scope) ->
        {:error, :authorization_changed}

      request.status in @live_request_statuses or is_nil(request.completed_at) ->
        {:error, :active_predecessor}

      request.status != "failed" or not admissible_failure?(request.last_error_code) ->
        {:error, :terminal_predecessor}

      live_turn?(request.id) or live_attempt?(request.id) ->
        {:error, :active_predecessor}

      entitlement?(request.id) ->
        {:error, :entitlement_present}

      true ->
        validate_retry_window(request.completed_at, now)
    end
  end

  # The provider ended the response (retryable first-event vocabulary) or the
  # Pooler's own response task died before settlement; nothing else is a verdict
  # the client may retry byte-identically through this path.
  defp admissible_failure?(code) when is_binary(code),
    do: code == @task_exception_code or ErrorCodes.retryable_first_event_code?(code)

  defp admissible_failure?(_code), do: false

  defp scoped?(%Request{} = request, scope) do
    request.pool_id == scope.pool_id and request.api_key_id == scope.api_key_id and
      request.model_id == scope.model_id and request.transport == "websocket" and
      request.endpoint == scope.endpoint
  end

  defp live_turn?(request_id) do
    Repo.all(
      from turn in CodexTurn,
        where: turn.request_id == ^request_id,
        select: {turn.status, turn.completed_at},
        lock: "FOR UPDATE"
    )
    |> Enum.any?(fn {status, completed_at} ->
      status == "in_progress" or is_nil(completed_at)
    end)
  end

  defp live_attempt?(request_id) do
    Repo.all(
      from attempt in Attempt,
        where: attempt.request_id == ^request_id,
        select: {attempt.status, attempt.completed_at},
        lock: "FOR UPDATE"
    )
    |> Enum.any?(fn {status, completed_at} ->
      status in @live_attempt_statuses or is_nil(completed_at)
    end)
  end

  defp entitlement?(request_id) do
    Repo.exists?(
      from entitlement in RequestReplayEntitlement,
        where: entitlement.request_id == ^request_id,
        lock: "FOR UPDATE"
    )
  end

  defp validate_retry_window(%DateTime{} = completed_at, %DateTime{} = now) do
    age = DateTime.diff(now, completed_at, :millisecond)

    if age in 0..(ClientRetry.retry_window_seconds() * 1_000),
      do: :ok,
      else: {:error, :retry_expired}
  end

  defp validate_retry_window(_completed_at, _now), do: {:error, :terminal_predecessor}

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end
end
