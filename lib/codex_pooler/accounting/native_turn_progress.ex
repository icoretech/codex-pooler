defmodule CodexPooler.Accounting.NativeTurnProgress do
  @moduledoc false

  # The full-history progress digest a native Codex request recorded on its row
  # (`NativeTurnContinuation.turn_progress/2`): the latest compaction pivot
  # (after a local compaction, which leaves none, the context window standing
  # in for it, findings#282) and the number of user messages after it, hashed.
  # A native HTTP request records it as `native_http_turn_progress` (findings#206
  # row 206-403); a websocket request as `native_turn_progress` when its socket
  # knew its history (row 206-412). Both are the same digest, so a later request
  # of a turn is compared with the turn's opener whatever transport either used.
  # Only the digest is ever stored; a row without one (written before these
  # releases, or by a socket that could not know the history) answers `nil`, and
  # its turn keeps the bare claim.
  #
  # A different digest is not enough to call a request a later one (findings#206
  # row 206-423): a resend of the holder with trimmed history differs too. Rows
  # therefore also record the position (`NativeTurnContinuation.progress_position/1`:
  # the pivot's digest, absent when there is none, and the count of user
  # messages after it), and a request is re-keyed only when it is further along
  # than the holder (`advances?/2`). A holder recorded by the previous release
  # carries the digest alone and cannot be ordered, so it keeps the bare claim.

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request, RequestClientRetryLink, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Persistence.SessionContinuity.MailboxAdmissionLocks
  alias CodexPooler.Repo

  @native_http_transports ["http_json", "http_sse", "http_compact_json"]

  @doc "The progress digest a request row recorded, url-safe Base64 without padding, or `nil`."
  @spec recorded(Request.t() | nil) :: String.t() | nil
  def recorded(%Request{transport: transport, request_metadata: %{"native_http_turn_progress" => %{"version" => 1, "digest" => digest}}})
      when transport in @native_http_transports and is_binary(digest),
      do: digest

  def recorded(%Request{transport: "websocket", request_metadata: %{"native_turn_progress" => %{"version" => 1, "digest" => digest}}})
      when is_binary(digest),
      do: digest

  def recorded(_request), do: nil

  @typedoc "Where a request stands in its turn: the pivot's digest (or `nil`) and the user messages after it."
  @type position :: {<<_::256>> | nil, non_neg_integer()}

  @type progression_scope :: %{
          required(:original_request_claim) => String.t(),
          required(:codex_session_id) => Ecto.UUID.t(),
          required(:semantic_turn_digest) => <<_::256>>,
          required(:pool_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:api_key_runtime_epoch) => non_neg_integer(),
          required(:model_id) => Ecto.UUID.t(),
          required(:requested_model) => String.t(),
          required(:endpoint) => String.t()
        }

  @doc """
  The position a request row recorded beside its progress digest, or `nil` when
  it recorded none (no digest at all, or a row of the previous release that
  recorded the digest alone).
  """
  @spec recorded_position(Request.t() | nil) :: position() | nil
  def recorded_position(%Request{} = request) do
    with digest when is_binary(digest) <- recorded(request),
         %{"user_messages" => count} = recorded when is_integer(count) and count >= 0 <- recorded_map(request),
         {:ok, pivot} <- recorded_pivot(Map.get(recorded, "pivot")) do
      {pivot, count}
    else
      _unordered -> nil
    end
  end

  def recorded_position(nil), do: nil

  @doc "The position recorded by the row holding `claim`, or `nil`."
  @spec recorded_position_for_claim(String.t()) :: position() | nil
  def recorded_position_for_claim(claim) when is_binary(claim) do
    Repo.one(
      from request in Request,
        where: request.correlation_id == ^claim,
        select: %Request{transport: request.transport, request_metadata: request.request_metadata}
    )
    |> recorded_position()
  end

  @doc "Checks whether a settled older request holds the interrupted request's user-steer position in this session."
  @spec older_settled_steer?(Ecto.UUID.t(), <<_::256>>, String.t(), String.t()) :: boolean()
  def older_settled_steer?(session_id, semantic_turn_digest, steer_claim, interrupted_claim) do
    newer =
      from turn in CodexTurn,
        where: turn.codex_session_id == ^session_id and turn.semantic_turn_digest == ^semantic_turn_digest,
        where: turn.turn_sequence > parent_as(:interrupted_turn).turn_sequence

    collision =
      from producer in Request,
        where: producer.correlation_id == ^interrupted_claim and not is_nil(producer.completed_at),
        join: current in CodexTurn,
        as: :interrupted_turn,
        on: current.request_id == producer.id,
        where: current.codex_session_id == ^session_id and current.semantic_turn_digest == ^semantic_turn_digest and not is_nil(current.completed_at),
        join: holder in Request,
        on: holder.correlation_id == ^steer_claim,
        where: holder.pool_id == producer.pool_id and holder.api_key_id == producer.api_key_id,
        where: holder.model_id == producer.model_id,
        join: prior in CodexTurn,
        on: prior.request_id == holder.id,
        where: prior.codex_session_id == ^session_id and prior.semantic_turn_digest == ^semantic_turn_digest,
        where: prior.turn_sequence < current.turn_sequence,
        where: not is_nil(holder.completed_at) and not is_nil(prior.completed_at),
        where: not exists(subquery(newer))

    Repo.exists?(collision)
  end

  # A pre-turn compaction can be the first request of a logical turn. Its
  # resume has a codex-resume claim, leaving no bare opener to compare a later
  # user steer with. The owner preflight calls this only after authorizing the
  # key/model and excluding active or armed work under the session locks.
  # Admission remains a fresh bare claim, exactly as on direct websocket/HTTP;
  # reservation and the owner still fence simultaneous candidates.
  @spec postcompaction_user_progress?(progression_scope(), position() | nil) :: boolean()
  def postcompaction_user_progress?(%{original_request_claim: "codex-turn:" <> _} = scope, {<<_::256>> = pivot, count})
      when is_integer(count) and count > 0 do
    with true <- MailboxAdmissionLocks.coordinated?(),
         :ok <- MailboxAdmissionLocks.require_session!(scope.codex_session_id),
         false <- Repo.exists?(from request in Request, where: request.correlation_id == ^scope.original_request_claim),
         %CodexTurn{status: status, completed_at: %DateTime{}} = turn when status in ["succeeded", "failed", "interrupted"] <- latest_turn(scope),
         %Request{} = request <- Repo.one(from request in Request, where: request.id == ^turn.request_id, lock: "FOR UPDATE"),
         true <- matching_resume?(request, scope),
         {^pivot, previous_count} when previous_count < count <- recorded_position(request),
         true <- terminal_attempt?(turn, request),
         false <- Repo.exists?(from entitlement in RequestReplayEntitlement, where: entitlement.request_id == ^request.id),
         false <- Repo.exists?(from link in RequestClientRetryLink, where: link.predecessor_request_id == ^request.id or link.successor_request_id == ^request.id) do
      true
    else
      _unproved -> false
    end
  end

  def postcompaction_user_progress?(_scope, _position), do: false

  defp latest_turn(scope) do
    Repo.one(
      from turn in CodexTurn,
        where: turn.codex_session_id == ^scope.codex_session_id and turn.semantic_turn_digest == ^scope.semantic_turn_digest,
        order_by: [desc: turn.turn_sequence],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp matching_resume?(%Request{correlation_id: "codex-resume:" <> _, transport: "websocket", status: status, completed_at: %DateTime{}} = request, scope)
       when status in ["succeeded", "failed"] do
    request.pool_id == scope.pool_id and request.api_key_id == scope.api_key_id and
      request.model_id == scope.model_id and request.requested_model == scope.requested_model and
      request.endpoint == scope.endpoint and request.native_client_retry_auth_epoch == scope.api_key_runtime_epoch and
      is_nil(request.request_metadata["released_turn_claim"])
  end

  defp matching_resume?(_request, _scope), do: false

  defp terminal_attempt?(%CodexTurn{final_attempt_id: final_attempt_id}, request) when is_binary(final_attempt_id) do
    Repo.exists?(
      from attempt in Attempt,
        where:
          attempt.id == ^final_attempt_id and attempt.request_id == ^request.id and
            attempt.status in ["succeeded", "failed", "cancelled"] and not is_nil(attempt.completed_at) and
            attempt.replay_generation == 0
    ) and not Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^request.id and is_nil(attempt.completed_at))
  end

  defp terminal_attempt?(_turn, _request), do: false

  @doc """
  True when a request at `position` is further along its turn than the holder
  of the turn's bare claim, which recorded `recorded`: the same compaction
  point (or none) and strictly more user messages after it (the user steered
  input in), or a compaction point the holder did not end on (a remote
  compaction replaced the history, keeping only messages and appending its
  item last; a local compaction moved the thread to another context window).
  A retry of the holder only appends model output, so it stands where the
  holder stood; a resend with trimmed history stands behind it. Both answer
  false, and so does a holder that recorded no position.
  """
  @spec advances?(position() | nil, position() | nil) :: boolean()
  def advances?({pivot, held}, {pivot, count}) when is_integer(held) and is_integer(count), do: count > held
  def advances?({_held_pivot, held}, {<<_::256>>, count}) when is_integer(held) and is_integer(count), do: true
  def advances?(_recorded, _position), do: false

  defp recorded_map(%Request{transport: "websocket", request_metadata: %{"native_turn_progress" => recorded}}), do: recorded
  defp recorded_map(%Request{request_metadata: %{"native_http_turn_progress" => recorded}}), do: recorded

  defp recorded_pivot(nil), do: {:ok, nil}

  defp recorded_pivot(pivot) when is_binary(pivot) do
    case Base.url_decode64(pivot, padding: false) do
      {:ok, <<_::256>> = decoded} -> {:ok, decoded}
      _invalid -> :error
    end
  end

  defp recorded_pivot(_pivot), do: :error

  @doc "The stored form of a progress digest."
  @spec encode(<<_::256>>) :: String.t()
  def encode(<<_::256>> = progress), do: Base.url_encode64(progress, padding: false)
end
