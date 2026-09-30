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
  # a provider verdict; the client disconnects admitted are a websocket turn
  # interrupted before any output reached the client and never armed for
  # replay, and a native compaction its client never completed), a stream error whose final attempt does not carry the
  # verified lifecycle-only or partial-reasoning cut evidence the client retry
  # policy requires, an anchored resend (a `previous_response_id` is bound to
  # the connection that produced it; the released client drops the anchor
  # before it retries), a replay entitlement, a scope mismatch, or an expired
  # retry window keeps the public `duplicate_turn` fence.

  import Ecto.Query

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    Request,
    RequestClientRetryLink,
    RequestReplayEntitlement
  }

  alias CodexPooler.Accounting.NativeHttpToolObservation
  alias CodexPooler.Accounting.RequestLifecycle
  alias CodexPooler.Accounting.RequestLifecycle.DeadExecutionResendRecovery
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Repo

  @max_chain_depth 16
  @task_exception_code "owner_task_exception"
  @stream_error_code "upstream_stream_error"
  @live_request_statuses ["accepted", "in_progress"]
  @live_attempt_statuses ["queued", "in_progress"]

  @type scope :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:model_id) => Ecto.UUID.t(),
          required(:endpoint) => String.t() | nil,
          optional(:codex_session_id) => Ecto.UUID.t(),
          optional(:semantic_turn_digest) => <<_::256>> | nil,
          optional(:native_client_retry_witness) => ClientRetry.OriginalWitness.t() | nil,
          optional(:native_http_input_count) => non_neg_integer() | nil,
          optional(:native_http_semantic_turn_key) => <<_::256>> | nil,
          optional(:native_http_transport) => String.t() | nil,
          optional(:payload) => map() | nil,
          optional(:mailbox_successor) => Request.t(),
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

  @type predecessor_shape ::
          :provider_terminal
          | :quota_rejection
          | :task_exception
          | :previsible_idle_timeout
          | :lifecycle_cut
          | :partial_reasoning_cut
          | :partial_http_tool_cut
          | :advanced_http_resume
          | :previsible_disconnect
          | :undelivered_completion
          | :undelivered_partial_output
          | :identical_resend
          | :completed_item_resend
          | :unreceived_compaction
          | :mailbox_continuation
          | :anchor_refusal
          | :compaction_cut

  @type resolution :: %{
          required(:claim) => String.t(),
          required(:predecessor) => Request.t(),
          required(:predecessor_shape) => predecessor_shape(),
          required(:recovery_markers) => [map()],
          optional(:execution_recovery?) => boolean()
        }

  @doc false
  @spec resolve(term(), scope()) :: {:ok, resolution()} | {:error, disposition()}
  def resolve(claim, scope) when is_binary(claim) and is_map(scope) do
    cond do
      not (WebsocketTurnIdentity.native_claim?(claim) or
               ClientRetry.failed_predecessor_claim?(claim)) ->
        {:error, :unsupported_claim}

      Map.get(scope, :anchor_present?) == true ->
        {:error, :anchor_unavailable}

      true ->
        resolve_chain(
          claim,
          nil,
          nil,
          scope
          |> Map.put(:semantic_claim?, semantic_claim?(claim))
          |> Map.put(:resume_claim?, resume_claim?(claim)),
          db_now(),
          [],
          0
        )
    end
  end

  def resolve(_claim, _scope), do: {:error, :unsupported_claim}

  @doc false
  @spec recoverable_predecessor(map()) :: Request.t() | nil
  def recoverable_predecessor(%{pool_id: pool_id, api_key_id: key_id, semantic_turn_digest: <<_::256>> = digest}) do
    lifecycle =
      Repo.one(
        from turn in CodexTurn,
          join: request in Request,
          on: request.id == turn.request_id,
          where: request.pool_id == ^pool_id and request.api_key_id == ^key_id and turn.semantic_turn_digest == ^digest,
          order_by: [desc: request.admitted_at, desc: turn.turn_sequence],
          limit: 1,
          select: {turn, request}
      )

    with {turn, request} <- lifecycle,
         false <- entitlement?(request.id),
         %Attempt{} = attempt <- latest_attempt(request.id),
         true <-
           ClientRetry.verified_dead_execution?(turn, request, attempt) or
             (request.status in @live_request_statuses and attempt.status in @live_attempt_statuses and
                not is_nil(RequestLifecycle.execution_recovery_authority(attempt))) do
      request
    else
      _not_recoverable -> nil
    end
  end

  def recoverable_predecessor(_scope), do: nil

  @doc false
  @spec resolve_execution(String.t(), map(), Ecto.UUID.t()) :: {:ok, resolution()} | {:error, disposition()}
  def resolve_execution(claim, scope, request_id) do
    turn = lock_turn(request_id)
    request = Repo.one(from request in Request, where: request.id == ^request_id, lock: "FOR UPDATE")

    with false <- Map.get(scope, :anchor_present?) == true,
         %Request{} <- request,
         true <- scoped?(request, scope),
         %CodexTurn{semantic_turn_digest: digest} <- turn,
         true <- digest == Map.get(scope, :semantic_turn_digest),
         false <- entitlement?(request.id),
         {:ok, request, marker} <- DeadExecutionResendRecovery.recover(request, true, db_now()),
         turn <- Repo.reload!(turn),
         attempt <- lock_final_attempt(turn, request.id),
         true <- ClientRetry.verified_dead_execution?(turn, request, attempt),
         {:ok, previous} <- execution_predecessor(request, turn, scope),
         shape <- if(completed_item_resend?(turn, request, attempt, scope), do: :completed_item_resend, else: :task_exception),
         :ok <- validate_semantic_retry(request, shape, Map.put(scope, :semantic_claim?, true), {previous, nil}),
         :ok <- validate_retry_window(request, attempt, db_now(), scope),
         {:ok, resolved_claim} <- execution_successor_claim(claim, request) do
      {:ok, %{claim: resolved_claim, predecessor: request, predecessor_shape: shape, recovery_markers: if(marker, do: [marker], else: []), execution_recovery?: true}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :terminal_predecessor}
    end
  end

  defp execution_predecessor(request, turn, scope) do
    previous =
      Repo.one(
        from link in RequestClientRetryLink,
          join: predecessor in Request,
          on: predecessor.id == link.predecessor_request_id,
          join: predecessor_turn in CodexTurn,
          on: predecessor_turn.request_id == predecessor.id,
          where: link.successor_request_id == ^request.id,
          select: {predecessor, predecessor_turn.semantic_turn_digest}
      )

    case previous do
      nil ->
        {:ok, nil}

      {%Request{} = predecessor, digest} when digest == turn.semantic_turn_digest ->
        if scoped?(predecessor, scope) and request.request_metadata["client_resend"]["predecessor_request_id"] == predecessor.id,
          do: {:ok, predecessor},
          else: {:error, :terminal_predecessor}

      _invalid ->
        {:error, :terminal_predecessor}
    end
  end

  defp execution_successor_claim(claim, request) do
    if Repo.exists?(from existing in Request, where: existing.correlation_id == ^claim),
      do: ClientRetry.deterministic_failed_predecessor_claim(request.correlation_id, request.id),
      else: {:ok, claim}
  end

  defp latest_attempt(request_id) do
    Repo.one(from attempt in Attempt, where: attempt.request_id == ^request_id, order_by: [desc: attempt.attempt_number], limit: 1)
  end

  defp semantic_claim?("codex-turn:" <> _digest), do: true
  defp semantic_claim?(_claim), do: false

  defp resume_claim?("codex-resume:" <> _digest), do: true
  defp resume_claim?(_claim), do: false

  defp resolve_chain(_claim, _predecessor, _shape, _scope, _now, _markers, depth)
       when depth > @max_chain_depth,
       do: {:error, :chain_exhausted}

  defp resolve_chain(claim, predecessor, shape, scope, now, markers, depth) do
    case lock_request_by_claim(claim) do
      nil when is_nil(predecessor) ->
        {:error, :missing_predecessor}

      nil ->
        if passed_compaction?(predecessor) do
          {:error, :terminal_predecessor}
        else
          {:ok,
           %{
             claim: claim,
             predecessor: predecessor,
             predecessor_shape: shape,
             recovery_markers: Enum.reverse(markers)
           }}
        end

      %Request{} = request ->
        continue_chain(request, predecessor, claim, scope, now, markers, depth)
    end
  end

  # A websocket compaction whose turn went on after it: a request of the same
  # session and turn is newer than the node the resend would chain onto. The
  # client sends its next request of a turn only once it completed the turn's
  # compaction, and resends only a compaction it did not complete, so that
  # resend repeats a compaction the client read and is refused, as the owner's
  # compaction policy refuses it with forwarding on (findings#270 row 270-357).
  # It used to be chained and billed with forwarding off. A compaction's
  # resends before the client goes on chain as before.
  defp passed_compaction?(%Request{id: request_id, endpoint: "/backend-api/codex/responses/compact", transport: "websocket"}) do
    case Repo.one(from(turn in CodexTurn, where: turn.request_id == ^request_id)) do
      %CodexTurn{codex_session_id: session_id, semantic_turn_digest: <<_::256>> = digest, turn_sequence: sequence} ->
        Repo.exists?(from(turn in CodexTurn, where: turn.codex_session_id == ^session_id and turn.semantic_turn_digest == ^digest and turn.turn_sequence > ^sequence))

      _no_turn ->
        false
    end
  end

  defp passed_compaction?(_predecessor), do: false

  defp continue_chain(request, previous, claim, scope, now, markers, depth) do
    with {:ok, derived} <-
           ClientRetry.deterministic_failed_predecessor_claim(claim, request.id),
         successor <- lock_request_by_claim(derived),
         scoped_validation <- scope_for_predecessor(scope, successor),
         {:ok, request, marker} <-
           DeadExecutionResendRecovery.recover(request, scoped?(request, scope), now),
         effective_now <- if(marker, do: db_now(), else: now),
         {:ok, request_shape} <-
           validate_predecessor(request, scoped_validation, effective_now),
         :ok <- validate_semantic_retry(request, request_shape, scoped_validation, {previous, successor}) do
      markers = if marker, do: [marker | markers], else: markers
      resolve_chain(derived, request, request_shape, scope, now, markers, depth + 1)
    end
  end

  defp scope_for_predecessor(scope, %Request{} = successor) do
    scope = scope |> Map.put(:successor_admitted?, true) |> Map.put(:mailbox_successor, successor)

    case successor.request_metadata["native_http_input_count"] do
      count when is_integer(count) and count >= 0 ->
        Map.put(scope, :native_http_validation_input_count, count)

      _missing ->
        scope
    end
  end

  defp scope_for_predecessor(scope, nil), do: scope

  # A turn claim does not bind payload bytes. Exact durable execution recovery,
  # a verified quota rejection before output, or a websocket turn the client
  # left before any output reached it still requires the original sealed
  # payload witness; payload-scoped continuation claims retain their policy.
  # The pre-visible disconnect is the released client's commonest resend: the
  # opening request of every turn carries this claim, and with owner
  # forwarding off it was refused on every retry (findings#232 row 232-170).
  # A provider stream cut before any completed output (lifecycle-only or
  # partial reasoning, both verified on the final attempt) is the other shape
  # the released client resends: with owner forwarding on the client-retry
  # preflight already admitted it, with forwarding off every resend of an
  # opening request was refused and the turn failed (row 232-174). An anchored
  # request refused because its connection cannot resolve the anchor is
  # resent in full the same way: with forwarding off the released client met
  # `409 duplicate_turn` on every resend and finished the turn over HTTPS
  # (row 232-278). So is a turn the provider ended with a retryable terminal
  # (`response.failed` `server_error`, overload), the shape the owner's
  # client-retry preflight already admits with forwarding on (findings#121
  # variant B, row 232-280).
  #
  # A turn has at most one successor per predecessor. A client-retry link
  # naming the request keeps the fence unless it is one of the chain's own
  # edges (`chain_edges_only?/2`).
  defp validate_semantic_retry(request, :partial_http_tool_cut, _scope, chain_edges) do
    if chain_edges_only?(request, chain_edges), do: :ok, else: {:error, :terminal_predecessor}
  end

  defp validate_semantic_retry(request, :mailbox_continuation, _scope, chain_edges) do
    if chain_edges_only?(request, chain_edges), do: :ok, else: {:error, :terminal_predecessor}
  end

  defp validate_semantic_retry(request, :identical_resend, %{semantic_claim?: false} = scope, chain_edges),
    do: validate_semantic_retry(request, :identical_resend, Map.put(scope, :semantic_claim?, true), chain_edges)

  defp validate_semantic_retry(request, shape, %{semantic_claim?: true} = scope, chain_edges) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    with %ClientRetry.OriginalWitness{version: 1, digest: digest, auth_epoch: epoch} = witness <-
           Map.get(scope, :native_client_retry_witness),
         true <- ClientRetry.original_witness_eligible?(request),
         true <- ClientRetry.witness_matches?(request.native_client_retry_digest, digest, witness.alternates) or shape == :completed_item_resend,
         true <- request.native_client_retry_auth_epoch == epoch,
         true <- chain_edges_only?(request, chain_edges),
         true <- semantic_retry_session_matches?(turn, request, attempt, scope),
         true <-
           ClientRetry.verified_dead_execution?(turn, request, attempt) or
             ClientRetry.verified_quota_rejection?(turn, request, attempt) or
             ClientRetry.verified_previous_response_miss?(turn, request, attempt) or
             ClientRetry.verified_provider_terminal_failure?(turn, request, attempt) or
             shape in [:previsible_idle_timeout, :identical_resend, :previsible_disconnect, :lifecycle_cut, :partial_reasoning_cut, :undelivered_completion, :undelivered_partial_output, :completed_item_resend, :unreceived_compaction] do
      :ok
    else
      _invalid -> {:error, :terminal_predecessor}
    end
  end

  defp validate_semantic_retry(_request, _shape, _scope, _chain_edges), do: :ok

  # The thread-scoped claim and sealed witness stay identical across a window
  # or session replacement. Only proven execution death can relax the session
  # fence; every other retry shape keeps its original session binding.
  defp semantic_retry_session_matches?(%CodexTurn{} = turn, request, attempt, scope),
    do: turn.codex_session_id == Map.get(scope, :codex_session_id) or ClientRetry.verified_dead_execution?(turn, request, attempt)

  defp semantic_retry_session_matches?(_turn, _request, _attempt, _scope), do: false

  # A turn-claim resend links its successor to the predecessor it chained onto,
  # so every node of a chain longer than one carries the chain's own edges: the
  # link from the node before it, and the link to the request holding the claim
  # derived from it, which this walk visits next and validates in turn. With
  # owner forwarding off a successor cut before any output reached the client
  # is itself a pre-visible disconnect, and refusing the chain's own edge met
  # the released client's next resend with `409 duplicate_turn` (findings#206
  # row 206-519). Any other link names a successor admitted under another claim
  # (the owner's `client-retry-v1:` preflight) or a predecessor outside the
  # chain, and chaining past it would admit a second successor of one request.
  defp chain_edges_only?(%Request{id: id}, {previous, successor}) do
    from(l in RequestClientRetryLink,
      where: l.predecessor_request_id == ^id or l.successor_request_id == ^id,
      select: {l.predecessor_request_id, l.successor_request_id}
    )
    |> Repo.all()
    |> Enum.all?(fn
      {^id, successor_id} -> match?(%Request{id: ^successor_id}, successor)
      {predecessor_id, ^id} -> match?(%Request{id: ^predecessor_id}, previous)
    end)
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
    family = failure_family(request.last_error_code)

    # A request of the same turn under the same authorization but on a
    # transport this claim does not resend (a native HTTP fallback met by a
    # websocket or HTTPS resend) is still the turn's own predecessor: a live
    # one is `active_predecessor` and a served one `terminal_predecessor`, not
    # a changed authorization (findings#206 row 206-534). A served one is
    # judged by `undelivered_completion/3`, whose shapes all require the
    # websocket or the native HTTP compaction claim domain, which never holds a
    # turn or resume chain claim; a failed one keeps `authorization_changed`,
    # because a websocket resend's `terminal_predecessor` also looks up a
    # recorded final refusal to relay.
    cond do
      not authorization_scoped?(request, scope) ->
        {:error, :authorization_changed}

      request.status in @live_request_statuses or is_nil(request.completed_at) ->
        {:error, :active_predecessor}

      identical_resend?(request, scope) or completed_item_resend?(request, scope) ->
        undelivered_completion(request, scope, now)

      request.status == "succeeded" ->
        undelivered_completion(request, scope, now)

      native_http_tool_scope?(request, scope) and request.last_error_code == "client_disconnected" ->
        admit_native_http_mailbox_continuation(request, scope, now)

      native_http_tool_scope?(request, scope) ->
        admit_native_http_partial_tool(request, scope, now)

      not transport_scoped?(request, scope) ->
        {:error, :authorization_changed}

      request.status != "failed" or (is_nil(family) and not websocket_compaction?(request)) ->
        {:error, :terminal_predecessor}

      live_turn?(request.id) or live_attempt?(request.id) ->
        {:error, :active_predecessor}

      entitlement?(request.id) ->
        {:error, :entitlement_present}

      websocket_compaction?(request) ->
        admit_compaction_predecessor(request, scope, now)

      true ->
        admit_predecessor(request, family, scope, now)
    end
  end

  # A failed native websocket compaction is judged by the rule the owner's
  # compaction retry policy applies with forwarding on
  # (`ClientRetry.compaction_resend_shape/3`), failing closed. The failure
  # families below used to admit every compaction whose code the retryable
  # first-event vocabulary names (`stream_incomplete` among them) whatever its
  # shape, and to refuse a pre-visible drain the owner's policy admits
  # (findings#270 rows 270-237 and 270-238).
  defp websocket_compaction?(%Request{endpoint: "/backend-api/codex/responses/compact", transport: "websocket"}), do: true
  defp websocket_compaction?(%Request{}), do: false

  defp admit_compaction_predecessor(request, scope, now) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    with {:ok, shape} <- ClientRetry.compaction_resend_shape(turn, request, attempt),
         :ok <- validate_retry_window(request, attempt, now, scope, ClientRetry.compaction_retry_window_seconds()),
         do: {:ok, shape}
  end

  # A client-side tool is dispatched only once its output_item.done arrives.
  # Unlike an absent receipt, this bounded observation proves the HTTP source
  # ended with only an incomplete tool. It authorizes one client-authored
  # exact successor under this chain's locks, never an automatic replay.
  defp native_http_tool_scope?(%Request{transport: "http_sse", request_metadata: %{"native_http_claim_arm" => arm}}, %{native_http_transport: "http_sse"}),
    do: arm in ["opening", "tool_continuation"]

  defp native_http_tool_scope?(_request, _scope), do: false

  defp admit_native_http_partial_tool(request, scope, now) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    with %Request{status: "failed", last_error_code: @stream_error_code, completed_at: %DateTime{}} <- request,
         %CodexTurn{status: "failed", error_code: @stream_error_code, completed_at: %DateTime{}, codex_session_id: session_id} <- turn,
         true <- session_id == Map.get(scope, :codex_session_id),
         %Attempt{status: "failed", transport: "http_sse", network_error_code: @stream_error_code, replay_generation: 0, completed_at: %DateTime{}} <- attempt,
         true <- NativeHttpToolObservation.eligible_metadata?(attempt.response_metadata["native_http_partial_tool"]),
         %ClientRetry.OriginalWitness{version: 1, digest: digest, auth_epoch: epoch} <- Map.get(scope, :native_client_retry_witness),
         true <- ClientRetry.original_witness_eligible?(request),
         true <- secure_compare(request.native_client_retry_digest, digest),
         true <- request.native_client_retry_auth_epoch == epoch,
         false <- Repo.exists?(from link in RequestClientRetryLink, where: link.successor_request_id == ^request.id),
         false <- live_turn?(request.id) or live_attempt?(request.id) or entitlement?(request.id),
         :ok <- validate_retry_window(request, attempt, now, scope) do
      {:ok, :partial_http_tool_cut}
    else
      {:error, :retry_expired} = error -> error
      _unsafe -> {:error, :terminal_predecessor}
    end
  end

  # An ordinary native HTTP request the client left after the Pooler delivered
  # completed items, resent with exactly those items and newly addressed
  # mailbox input appended (`ClientRetry.verified_mailbox_continuation?/5`).
  # Only an opener shares its claim with such a resend; a tool continuation's
  # grown resend derives another payload-scoped claim and never reaches here.
  defp admit_native_http_mailbox_continuation(request, scope, now) do
    cond do
      request.status != "failed" -> {:error, :terminal_predecessor}
      live_turn?(request.id) or live_attempt?(request.id) -> {:error, :active_predecessor}
      entitlement?(request.id) -> {:error, :entitlement_present}
      not mailbox_continuation?(request, scope) -> {:error, :terminal_predecessor}
      true -> with :ok <- validate_retry_window(request, request.id |> lock_turn() |> lock_final_attempt(request.id), now, scope), do: {:ok, :mailbox_continuation}
    end
  end

  # A completed turn whose socket pushed nothing of it to the client, or only
  # frames after which the released client resends the identical request (the
  # client resends it); `ClientRetry.verified_undelivered_completion?/3`
  # (findings#232 row 232-201) and `verified_undelivered_partial_output?/3`
  # (row 232-203). Or completed items and no terminal, after which the client
  # resends it with those items appended (`verified_completed_item_resend?/4`,
  # row 232-232). The turn-claim branch still requires the witness. A native
  # compaction billed but never completed by its client is resent under its
  # compaction claim, which binds the window the client advances after every
  # compaction it completes (`ClientRetry.verified_unreceived_compaction?/3`,
  # findings#206 row 206-330).
  defp undelivered_completion(request, scope, now) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)
    shape = undelivered_completion_shape(turn, request, attempt, scope)

    cond do
      not resend_claim_scope?(scope, shape) -> {:error, :terminal_predecessor}
      is_nil(shape) -> {:error, :terminal_predecessor}
      live_turn?(request.id) or live_attempt?(request.id) -> {:error, :active_predecessor}
      entitlement?(request.id) -> {:error, :entitlement_present}
      true -> with :ok <- validate_retry_window(request, attempt, now, scope, shape_retry_window_seconds(shape)), do: {:ok, shape}
    end
  end

  defp resend_claim_scope?(_scope, :unreceived_compaction), do: true
  defp resend_claim_scope?(%{semantic_claim?: true}, _shape), do: true
  defp resend_claim_scope?(_scope, :identical_resend), do: true
  defp resend_claim_scope?(_scope, _shape), do: false

  # A compaction the client never read is resent after the client's stream
  # idle timeout when its reply was lost silently, so it keeps the compaction
  # window (`ClientRetry.compaction_retry_window_seconds/0`, findings#270 row
  # 270-373); every other shape keeps the ordinary one.
  defp shape_retry_window_seconds(:unreceived_compaction), do: ClientRetry.compaction_retry_window_seconds()
  defp shape_retry_window_seconds(_shape), do: ClientRetry.retry_window_seconds()

  defp undelivered_completion_shape(turn, request, attempt, scope) do
    cond do
      identical_resend?(turn, request, attempt, scope) -> :identical_resend
      ClientRetry.verified_unreceived_compaction?(turn, request, attempt) -> :unreceived_compaction
      ClientRetry.verified_undelivered_completion?(turn, request, attempt) -> :undelivered_completion
      ClientRetry.verified_undelivered_partial_output?(turn, request, attempt) -> :undelivered_partial_output
      completed_item_resend?(turn, request, attempt, scope) -> :completed_item_resend
      true -> nil
    end
  end

  defp identical_resend?(request, scope) do
    turn = lock_turn(request.id)
    identical_resend?(turn, request, lock_final_attempt(turn, request.id), scope)
  end

  defp identical_resend?(turn, request, attempt, scope) do
    with %ClientRetry.OriginalWitness{version: 1, digest: digest, alternates: alternates} <- Map.get(scope, :native_client_retry_witness),
         true <- ClientRetry.witness_matches?(request.native_client_retry_digest, digest, alternates) do
      ClientRetry.verified_identical_resend?(turn, request, attempt)
    else
      _mismatch -> false
    end
  end

  # The resend is the predecessor with exactly the completed items its socket
  # proved it pushed appended: the witness names the predecessor through one of
  # the resend's grown candidates, and the receipt names the same items
  # (findings#232 row 232-232).
  defp completed_item_resend?(turn, request, attempt, scope) do
    case Map.get(scope, :native_client_retry_witness) do
      %ClientRetry.OriginalWitness{grown: [_first | _rest] = grown} ->
        case ClientRetry.grown_witness_candidates(request, grown) do
          [] -> false
          candidates -> ClientRetry.verified_completed_item_resend?(turn, request, attempt, candidates)
        end

      _no_grown_candidates ->
        false
    end
  end

  defp admit_predecessor(request, family, scope, now) do
    with {:ok, shape} <- predecessor_shape(request, family, scope),
         :ok <- validate_retry_window(request, request.id |> lock_turn() |> lock_final_attempt(request.id), now, scope),
         do: {:ok, shape}
  end

  # The provider ended the response (retryable first-event vocabulary), the
  # Pooler's own response task died before settlement, or the stream was cut
  # under the receive loop; nothing else is a verdict the client may retry
  # byte-identically through this path.
  defp failure_family(@task_exception_code), do: :task_exception
  defp failure_family("dead_execution_recovered"), do: :dead_execution
  defp failure_family("absent_instance_recovered"), do: :dead_execution
  defp failure_family(@stream_error_code), do: :stream_cut
  defp failure_family("stream_idle_timeout"), do: :idle_timeout
  defp failure_family("client_disconnected"), do: :client_disconnect

  defp failure_family(code) when code in ["usage_limit_reached", "usage_limit_exceeded"],
    do: :quota_rejection

  defp failure_family(code) when is_binary(code) do
    if ErrorCodes.retryable_first_event_code?(code), do: :provider_terminal
  end

  defp failure_family(_code), do: nil

  defp predecessor_shape(_request, family, _scope)
       when family in [:provider_terminal, :task_exception],
       do: {:ok, family}

  defp predecessor_shape(%Request{} = request, :dead_execution, _scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    if ClientRetry.verified_dead_execution?(turn, request, attempt),
      do: {:ok, :task_exception},
      else: {:error, :terminal_predecessor}
  end

  defp predecessor_shape(%Request{} = request, :quota_rejection, _scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    if ClientRetry.verified_quota_rejection?(turn, request, attempt),
      do: {:ok, :quota_rejection},
      else: {:error, :terminal_predecessor}
  end

  defp predecessor_shape(%Request{} = request, :idle_timeout, _scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    if ClientRetry.verified_previsible_idle_timeout?(turn, request, attempt),
      do: {:ok, :previsible_idle_timeout},
      else: {:error, :terminal_predecessor}
  end

  # A stream cut may have delivered completed output items, so it is admitted
  # only with the evidence the client retry policy verifies for the same
  # failure on the turn's final attempt: a lifecycle-only cut or a
  # partial-reasoning cut. Both rows are read under the session lock this claim
  # already holds.
  defp predecessor_shape(%Request{} = request, :stream_cut, _scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    cond do
      ClientRetry.verified_lifecycle_cut?(turn, request, attempt) ->
        {:ok, :lifecycle_cut}

      ClientRetry.verified_partial_reasoning_cut?(turn, request, attempt) ->
        {:ok, :partial_reasoning_cut}

      true ->
        {:error, :terminal_predecessor}
    end
  end

  defp predecessor_shape(%Request{} = request, :client_disconnect, scope) do
    cond do
      mailbox_continuation?(request, scope) -> {:ok, :mailbox_continuation}
      advanced_http_resume?(request, scope) -> {:ok, :advanced_http_resume}
      previsible_websocket_disconnect?(request) -> {:ok, :previsible_disconnect}
      unreceived_compaction?(request) -> {:ok, :unreceived_compaction}
      undelivered_partial_output?(request) -> {:ok, :undelivered_partial_output}
      completed_item_resend?(request, scope) -> {:ok, :completed_item_resend}
      true -> {:error, :terminal_predecessor}
    end
  end

  # A resume after compaction, or an ordinary turn opener under its bare claim.
  defp mailbox_continuation?(request, %{resume_claim?: true} = scope), do: verified_mailbox_continuation?(request, scope)
  defp mailbox_continuation?(request, %{semantic_claim?: true} = scope), do: verified_mailbox_continuation?(request, scope)
  defp mailbox_continuation?(_request, _scope), do: false

  defp verified_mailbox_continuation?(request, scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    match?(%CodexTurn{codex_session_id: session_id} when session_id == scope.codex_session_id, turn) and
      ClientRetry.verified_mailbox_continuation?(turn, request, attempt, Map.get(scope, :native_client_retry_witness), Map.get(scope, :mailbox_successor))
  end

  defp completed_item_resend?(%Request{} = request, scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)
    completed_item_resend?(turn, request, attempt, scope)
  end

  # A websocket turn whose client left after seeing only frames the released
  # client discards (lifecycle, an item or part opening, deltas): the closing
  # socket or the owner stopped its generation, and the client resends the
  # identical request (findings#232 row 232-203,
  # `ClientRetry.verified_undelivered_partial_output?/3`).
  defp undelivered_partial_output?(%Request{} = request) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)
    ClientRetry.verified_undelivered_partial_output?(turn, request, attempt)
  end

  # A native compaction the client left while the Pooler was still collecting
  # it: nothing of it was written to the client (findings#206 row 206-332).
  defp unreceived_compaction?(%Request{} = request) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)
    ClientRetry.verified_unreceived_compaction?(turn, request, attempt)
  end

  defp lock_turn(request_id) do
    Repo.one(
      from turn in CodexTurn,
        where: turn.request_id == ^request_id,
        lock: "FOR UPDATE"
    )
  end

  # The turn's final attempt must also be the request's latest attempt; any
  # other pairing is not the cut the resend repeats.
  defp lock_final_attempt(%CodexTurn{final_attempt_id: attempt_id}, request_id)
       when is_binary(attempt_id) do
    case Repo.one(
           from attempt in Attempt,
             where: attempt.request_id == ^request_id,
             order_by: [desc: attempt.attempt_number],
             limit: 1,
             lock: "FOR UPDATE"
         ) do
      %Attempt{id: ^attempt_id} = attempt -> attempt
      _other -> nil
    end
  end

  defp lock_final_attempt(_turn, _request_id), do: nil

  defp scoped?(%Request{} = request, scope),
    do: authorization_scoped?(request, scope) and transport_scoped?(request, scope)

  defp authorization_scoped?(%Request{} = request, scope) do
    request.pool_id == scope.pool_id and request.api_key_id == scope.api_key_id and
      request.model_id == scope.model_id and request.endpoint == scope.endpoint
  end

  defp transport_scoped?(%Request{transport: "websocket"}, _scope), do: true

  defp transport_scoped?(
         %Request{
           transport: transport,
           request_metadata: %{"native_http_claim_arm" => "post_compaction_resume"}
         },
         %{resume_claim?: true}
       )
       when transport in ["http_sse", "http_json"],
       do: true

  # A native HTTP compaction is met again only by a request deriving its own
  # compaction-domain claim, i.e. the same compaction resent over native HTTP;
  # whether it may be chained is `ClientRetry.verified_unreceived_compaction?/3`'s
  # verdict (findings#206 row 206-404).
  defp transport_scoped?(
         %Request{transport: transport, request_metadata: %{"native_http_claim_arm" => "compaction"}},
         %{semantic_claim?: false, resume_claim?: false}
       )
       when transport in ["http_json", "http_sse", "http_compact_json"],
       do: true

  defp transport_scoped?(%Request{}, _scope), do: false

  defp advanced_http_resume?(%Request{} = request, scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    with %CodexTurn{
           status: "interrupted",
           error_code: "client_disconnected",
           first_visible_output_at: %DateTime{},
           completed_at: %DateTime{}
         } <- turn,
         %Attempt{
           status: "failed",
           network_error_code: "client_disconnected",
           transport: "http_sse",
           replay_generation: 0,
           completed_at: %DateTime{}
         } <- attempt,
         %ClientRetry.OriginalWitness{version: 1, digest: digest, auth_epoch: epoch} <-
           Map.get(scope, :native_client_retry_witness),
         true <- ClientRetry.original_witness_eligible?(request),
         true <- request.native_client_retry_auth_epoch == epoch,
         previous_count when is_integer(previous_count) and previous_count >= 0 <-
           request.request_metadata["native_http_input_count"],
         current_count when is_integer(current_count) and current_count > previous_count <-
           validation_input_count(scope),
         <<_::256>> = semantic_turn_key <- Map.get(scope, :native_http_semantic_turn_key),
         %{"input" => input} when is_list(input) <- Map.get(scope, :payload),
         suffix when suffix != [] <-
           Enum.slice(input, previous_count, current_count - previous_count),
         true <-
           ClientRetry.native_http_progress_matches?(
             attempt.response_metadata["native_http_resume_progress"],
             suffix
           ),
         {:ok, prefix_digest} <-
           WebsocketTurnIdentity.http_resume_input_digest(
             semantic_turn_key,
             Enum.take(input, previous_count)
           ),
         true <- secure_compare(request.native_client_retry_digest, prefix_digest),
         false <- secure_compare(request.native_client_retry_digest, digest) do
      true
    else
      _unsafe -> false
    end
  end

  # A websocket turn whose client went away before any output reached it.
  # With owner forwarding on the owner arms this cut as a replay entitlement
  # (which `validate_predecessor/3` already refuses here); with forwarding off,
  # or when the owner could not suspend it, nothing is armed, and the released
  # client's byte-identical resend used to meet `duplicate_turn` on every
  # websocket retry until it fell back to HTTPS (findings#232 row 232-112).
  # The turn row is authoritative for visibility: the Pooler stamps
  # `first_visible_output_at` before it writes any provider event, error
  # events included, to the client. Only generation zero qualifies; a
  # replayed generation keeps the fence.
  defp previsible_websocket_disconnect?(%Request{} = request) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    match?(
      {%CodexTurn{status: "interrupted", error_code: "client_disconnected", transport_kind: "websocket", first_visible_output_at: nil, completed_at: %DateTime{}}, %Attempt{status: "failed", network_error_code: "client_disconnected", transport: "websocket", replay_generation: 0, completed_at: %DateTime{}}},
      {turn, attempt}
    ) and request.transport == "websocket"
  end

  defp validation_input_count(scope) do
    Map.get(scope, :native_http_validation_input_count) ||
      Map.get(scope, :native_http_input_count)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false

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

  # A chain node the walk passes through already had its successor admitted
  # inside its window, so only the node the resend chains onto is held to one.
  # The released client's retries of a turn are paced by its own backoff and by
  # how long each successor ran before it was cut, and with owner forwarding off
  # a chain of pre-visible cuts could outlast its first request's window and
  # meet `409 duplicate_turn` (findings#206 row 206-519).
  defp validate_retry_window(request, attempt, now, scope),
    do: validate_retry_window(request, attempt, now, scope, ClientRetry.retry_window_seconds())

  defp validate_retry_window(_request, _attempt, _now, %{successor_admitted?: true}, _window_seconds), do: :ok

  # From the predecessor's completion, or from the failed downstream write its
  # final attempt's receipt names (`ClientRetry.retry_window_start/3`,
  # findings#232 row 232-261).
  defp validate_retry_window(%Request{} = request, attempt, %DateTime{} = now, _scope, window_seconds),
    do: validate_window_age(ClientRetry.retry_window_start(request, attempt, now), now, window_seconds)

  defp validate_window_age(%DateTime{} = started_at, %DateTime{} = now, window_seconds) do
    age = DateTime.diff(now, started_at, :millisecond)

    if age in 0..(window_seconds * 1_000),
      do: :ok,
      else: {:error, :retry_expired}
  end

  defp validate_window_age(_completed_at, _now, _window_seconds), do: {:error, :terminal_predecessor}

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end
end
