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
  # a provider verdict; the one client disconnect admitted is a websocket turn
  # interrupted before any output reached the client and never armed for
  # replay), a stream error whose final attempt does not carry the
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
          optional(:native_client_retry_witness) => ClientRetry.OriginalWitness.t() | nil,
          optional(:native_http_input_count) => non_neg_integer() | nil,
          optional(:native_http_semantic_turn_key) => <<_::256>> | nil,
          optional(:payload) => map() | nil,
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
          | :lifecycle_cut
          | :partial_reasoning_cut
          | :advanced_http_resume
          | :previsible_disconnect

  @type resolution :: %{
          claim: String.t(),
          predecessor: Request.t(),
          predecessor_shape: predecessor_shape(),
          recovery_markers: [map()]
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
        {:ok,
         %{
           claim: claim,
           predecessor: predecessor,
           predecessor_shape: shape,
           recovery_markers: Enum.reverse(markers)
         }}

      %Request{} = request ->
        continue_chain(request, claim, scope, now, markers, depth)
    end
  end

  defp continue_chain(request, claim, scope, now, markers, depth) do
    with {:ok, derived} <-
           ClientRetry.deterministic_failed_predecessor_claim(claim, request.id),
         successor <- lock_request_by_claim(derived),
         scoped_validation <- scope_for_predecessor(scope, successor),
         {:ok, request, marker} <-
           DeadExecutionResendRecovery.recover(request, scoped?(request, scope), now),
         effective_now <- if(marker, do: db_now(), else: now),
         {:ok, request_shape} <-
           validate_predecessor(request, scoped_validation, effective_now),
         :ok <- validate_semantic_retry(request, scoped_validation) do
      markers = if marker, do: [marker | markers], else: markers
      resolve_chain(derived, request, request_shape, scope, now, markers, depth + 1)
    end
  end

  defp scope_for_predecessor(scope, %Request{} = successor) do
    case successor.request_metadata["native_http_input_count"] do
      count when is_integer(count) and count >= 0 ->
        Map.put(scope, :native_http_validation_input_count, count)

      _missing ->
        scope
    end
  end

  defp scope_for_predecessor(scope, nil), do: scope

  # A turn claim does not bind payload bytes. Exact durable execution recovery
  # or a verified quota rejection before output still requires the original
  # sealed payload witness; payload-scoped continuation claims retain their policy.
  defp validate_semantic_retry(request, %{semantic_claim?: true} = scope) do
    turn = lock_turn(request.id)
    attempt = lock_final_attempt(turn, request.id)

    with %ClientRetry.OriginalWitness{version: 1, digest: digest, auth_epoch: epoch} = witness <-
           Map.get(scope, :native_client_retry_witness),
         true <- ClientRetry.original_witness_eligible?(request),
         true <- ClientRetry.witness_matches?(request.native_client_retry_digest, digest, witness.alternates),
         true <- request.native_client_retry_auth_epoch == epoch,
         false <-
           Repo.exists?(
             from l in RequestClientRetryLink,
               where: l.predecessor_request_id == ^request.id or l.successor_request_id == ^request.id
           ),
         true <- not is_nil(turn) and turn.codex_session_id == Map.get(scope, :codex_session_id),
         true <-
           ClientRetry.verified_dead_execution?(turn, request, attempt) or
             ClientRetry.verified_quota_rejection?(turn, request, attempt) do
      :ok
    else
      _invalid -> {:error, :terminal_predecessor}
    end
  end

  defp validate_semantic_retry(_request, _scope), do: :ok

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

    cond do
      not scoped?(request, scope) ->
        {:error, :authorization_changed}

      request.status in @live_request_statuses or is_nil(request.completed_at) ->
        {:error, :active_predecessor}

      request.status != "failed" or is_nil(family) ->
        {:error, :terminal_predecessor}

      live_turn?(request.id) or live_attempt?(request.id) ->
        {:error, :active_predecessor}

      entitlement?(request.id) ->
        {:error, :entitlement_present}

      true ->
        admit_predecessor(request, family, scope, now)
    end
  end

  defp admit_predecessor(request, family, scope, now) do
    with {:ok, shape} <- predecessor_shape(request, family, scope),
         :ok <- validate_retry_window(request.completed_at, now),
         do: {:ok, shape}
  end

  # The provider ended the response (retryable first-event vocabulary), the
  # Pooler's own response task died before settlement, or the stream was cut
  # under the receive loop; nothing else is a verdict the client may retry
  # byte-identically through this path.
  defp failure_family(@task_exception_code), do: :task_exception
  defp failure_family("dead_execution_recovered"), do: :dead_execution
  defp failure_family(@stream_error_code), do: :stream_cut
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
      advanced_http_resume?(request, scope) -> {:ok, :advanced_http_resume}
      previsible_websocket_disconnect?(request) -> {:ok, :previsible_disconnect}
      true -> {:error, :terminal_predecessor}
    end
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

  defp scoped?(%Request{} = request, scope) do
    request.pool_id == scope.pool_id and request.api_key_id == scope.api_key_id and
      request.model_id == scope.model_id and request.endpoint == scope.endpoint and
      transport_scoped?(request, scope)
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
