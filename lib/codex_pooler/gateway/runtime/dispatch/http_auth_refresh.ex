defmodule CodexPooler.Gateway.Runtime.Dispatch.HttpAuthRefresh do
  @moduledoc false

  # HTTP counterpart of the websocket terminal auth refresh: a provider 401
  # (or an auth-coded 403) on an HTTP attempt is not yet visible to the client,
  # so a repairable credential failure refreshes the access token once through
  # the shared fenced helper and retries the same identity. Runtime assertion
  # denials cannot be repaired by refreshing the account token. Exhausted auth fails
  # over to the next eligible candidate under the ordinary retry policy and
  # only the last candidate finalizes a retryable public 503. Runtime denials
  # bypass refresh and keep the existing non-refresh failure projection.

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Runtime.Dispatch.AuthRefresh
  alias CodexPooler.Gateway.Runtime.Dispatch.ContentFilterBindingRefusal
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Gateway.Runtime.Finalization.SettlementAttrs
  alias CodexPooler.Gateway.Runtime.Finalization.SideEffects
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Repo

  @compact_endpoint "/backend-api/codex/responses/compact"
  @error_kind "http_auth_refresh"

  @type dispatch_result :: CodexPooler.Gateway.Runtime.Dispatch.dispatch_result()
  @type redispatch :: (PreparedContext.t() -> dispatch_result())

  @spec eligible?(PreparedContext.t(), Req.Response.t()) :: boolean()
  def eligible?(%PreparedContext{context: context}, %Req.Response{} = response) do
    auth_failure?(response) and not AuthRefresh.retry_suppressed?(context)
  end

  @spec auth_failure?(Req.Response.t()) :: boolean()
  def auth_failure?(%Req.Response{} = response), do: Metadata.http_auth_failure_kind(response) == :credential

  @spec handle(PreparedContext.t(), Req.Response.t(), redispatch()) :: dispatch_result()
  def handle(
        %PreparedContext{context: %SelectedCandidateContext{} = context} = prepared_context,
        %Req.Response{} = response,
        redispatch
      )
      when is_function(redispatch, 1) do
    if context.auth_refresh_retry_attempted? == true do
      finalize_exhausted(context, response, recorded?: false)
    else
      refresh_and_retry(prepared_context, response, redispatch)
    end
  end

  defp refresh_and_retry(
         %PreparedContext{context: context} = prepared_context,
         response,
         redispatch
       ) do
    case record_first_attempt_failure(context, response) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _recorded_failure} ->
        refresh_then_retry_or_exhaust(prepared_context, context, response, redispatch)

      {:error, _reason} = error ->
        error
    end
  end

  defp refresh_then_retry_or_exhaust(prepared_context, context, response, redispatch) do
    case AuthRefresh.refresh(context, :http) do
      {:ok, refresh_metadata, refreshed_identity} ->
        with {:ok, refreshed_context} <- record_metadata(context, refresh_metadata),
             {:ok, retry_context} <-
               same_identity_retry_context(%{
                 refreshed_context
                 | identity: refreshed_identity,
                   auth_refresh_retry_attempted?: true
               }) do
          redispatch_with_refreshed_token(prepared_context, retry_context, redispatch)
        end

      {:refresh_not_retryable, %{"status" => "refresh_in_progress"} = refresh_metadata} ->
        with {:ok, refreshed_context} <- record_metadata(context, refresh_metadata) do
          finish_refresh_follower(refreshed_context, response)
        end

      {:refresh_not_retryable, refresh_metadata} ->
        with {:ok, refreshed_context} <- record_metadata(context, refresh_metadata) do
          finalize_exhausted(refreshed_context, response, recorded?: true)
        end
    end
  end

  defp record_metadata(context, metadata) do
    case AuthRefresh.record_metadata(context, metadata, :merge_http_auth_refresh_metadata) do
      {:ok, refreshed_context} -> {:ok, refreshed_context}
      {:error, reason} -> finalize_retry_accounting_failure(context, reason, :merge_http_auth_refresh_metadata)
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      finalize_retry_accounting_failure(context, error, :merge_http_auth_refresh_metadata)
  end

  defp finish_refresh_follower(context, response) do
    if failover?(context) do
      with :ok <- DispatchLifecycle.neutral_completion(context),
           do: {:retry, unauthorized_code()}
    else
      finalize_failure(context, response, true, fn ->
        DispatchLifecycle.neutral_completion(context)
      end)
    end
  end

  defp redispatch_with_refreshed_token(prepared_context, retry_context, redispatch) do
    case AuthRefresh.decrypt_access_token(retry_context.identity) do
      {:ok, refreshed_token} ->
        redispatch.(%{prepared_context | context: retry_context, token: refreshed_token})

      {:error, reason} ->
        Finalization.handle_dispatch_error(
          reason,
          retry_context,
          elapsed_ms(retry_context.started)
        )
    end
  end

  defp record_first_attempt_failure(context, response) do
    AttemptSettlement.record_retryable_failure(context.reserved.request, context.attempt, %{
      response_status_code: response.status,
      last_error_code: unauthorized_code(),
      error_message: "upstream http auth failed before visible output",
      latency_ms: elapsed_ms(context.started),
      attempt_metadata: attempt_metadata(context, response),
      retry_count: context.retry_count,
      before_finalize: fn -> observe_response(context, response) end
    })
  end

  # Exhausted auth (refresh not retryable, or a second rejection after the
  # refreshed retry) marks the identity through the ordinary route-failure and
  # gateway reconciliation paths, then either fails over or finalizes. An
  # attempt already recorded as retryable before the refresh is not recorded
  # twice: only the final settlement may replace a retryable record.
  defp finalize_exhausted(context, response, opts) do
    recorded? = Keyword.fetch!(opts, :recorded?)

    cond do
      failover?(context) and recorded? -> failover_after_recorded_failure(context)
      failover?(context) -> record_failover(context, response)
      true -> finalize_failure(context, response, recorded?)
    end
  end

  defp failover?(%SelectedCandidateContext{allow_retry?: true, endpoint: endpoint}),
    do: endpoint != @compact_endpoint

  defp failover?(%SelectedCandidateContext{}), do: false

  defp failover_after_recorded_failure(context) do
    case mark_identity_unauthorized(context) do
      :ok -> {:retry, unauthorized_code()}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp record_failover(context, response) do
    case AttemptSettlement.record_retryable_failure(context.reserved.request, context.attempt, %{
           response_status_code: response.status,
           last_error_code: unauthorized_code(),
           error_message: "upstream http auth failed after credential refresh",
           latency_ms: elapsed_ms(context.started),
           attempt_metadata: attempt_metadata(context, response),
           retry_count: context.retry_count,
           before_finalize: exhausted_side_effects(context, response, false)
         }) do
      {:stale_generation, finalized} -> {:ok, finalized}
      {:ok, _attempt} -> {:retry, unauthorized_code()}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp finalize_failure(context, response, recorded?, side_effects \\ nil) do
    attrs =
      SettlementAttrs.failure(
        context,
        ErrorCodes.upstream_unauthorized_status(),
        unauthorized_code(),
        ErrorCodes.upstream_unauthorized_message(),
        attempt_metadata(context, response),
        latency_ms: elapsed_ms(context.started),
        usage: %{status: "usage_unknown", source: "upstream_status"},
        before_finalize: side_effects || exhausted_side_effects(context, response, recorded?)
      )

    case AttemptSettlement.finalize_failure(
           context.reserved.request,
           context.attempt,
           attrs,
           context.request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} ->
        {:error,
         %{
           status: ErrorCodes.upstream_unauthorized_status(),
           code: unauthorized_code(),
           message: ErrorCodes.upstream_unauthorized_message(),
           param: nil
         }}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  # The upstream response is observed once per attempt record; a prior
  # retryable record already observed it, so only the identity marking repeats.
  defp exhausted_side_effects(context, response, recorded?) do
    fn ->
      unless recorded?, do: observe_response(context, response)
      mark_identity_unauthorized(context)
    end
  end

  defp mark_identity_unauthorized(context) do
    SideEffects.maybe_enqueue_gateway_reconciliation(
      context.reserved.request.pool_id,
      context.assignment
    )

    case DispatchLifecycle.failure(context, unauthorized_code()) do
      {:ok, _demotion_reason} -> :ok
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp observe_response(context, response),
    do: SideEffects.observe_http_response(context, response, Metadata.response_body(response))

  # Same assignment and identity, fresh attempt row, and the candidate's
  # failover eligibility preserved so a second rejection can still move on.
  defp same_identity_retry_context(context) do
    case Accounting.create_attempt(context.reserved.request, context.assignment, %{
           model: context.model,
           pricing_snapshot: Map.get(context.reserved, :pricing_snapshot),
           upstream_identity: context.identity,
           response_metadata:
             Map.merge(context.request_options.routing.routing_attempt_metadata || %{}, %{
               "pool_upstream_assignment_id" => context.assignment.id,
               "upstream_identity_id" => context.identity.id
             })
         }) do
      {:ok, attempt} ->
        {:ok,
         %{
           context
           | attempt: attempt,
             started: System.monotonic_time(:millisecond),
             retry_count: context.retry_count + 1
         }}

      {:error, %{code: :request_already_finalized}} ->
        {:error,
         %{
           status: 499,
           code: "request_already_finalized",
           message: "request lifecycle completed before upstream dispatch"
         }}

      # A content-filter retry binding the retry can no longer honour
      # (`ContentFilterBindingRefusal`, findings#316).
      {:error, %{code: :invalid_content_filter_retry_binding}} ->
        ContentFilterBindingRefusal.finalize_retry(context)

      {:error, reason} ->
        finalize_retry_accounting_failure(context, reason)
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      finalize_retry_accounting_failure(context, error)
  end

  defp finalize_retry_accounting_failure(context, reason, operation \\ :create_same_identity_http_retry_attempt) do
    {:error, error} = FailureResponse.accounting_failure(operation, context.reserved.request, context.attempt, reason)
    attrs = SettlementAttrs.failure(context, error.status, error.code, error.message, %{}, latency_ms: elapsed_ms(context.started), before_finalize: fn -> complete_failed_retry_if_current(context) end)
    _cleanup = cleanup_retry_accounting(context, attrs)
    {:error, error}
  end

  defp cleanup_retry_accounting(context, attrs) do
    AttemptSettlement.finalize_failure(context.reserved.request, context.attempt, attrs, context.request_options.runtime.session_owner_witness)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      FailureResponse.accounting_failure(:cleanup_http_auth_refresh_accounting, context.reserved.request, context.attempt, error)
  end

  # The finalizer holds the request and attempt locks here. A later attempt or
  # terminal writer owns its own state; cleanup must not replace that work.
  defp complete_failed_retry_if_current(context) do
    request = Repo.get!(Request, context.reserved.request.id)
    latest_id = Repo.one(from attempt in Attempt, where: attempt.request_id == ^request.id, order_by: [desc: attempt.attempt_number], limit: 1, select: attempt.id)

    if request.status in ["accepted", "in_progress"] and is_nil(request.completed_at) and latest_id == context.attempt.id do
      DispatchLifecycle.neutral_completion(context)
    else
      {:error, :stale_http_auth_refresh_cleanup}
    end
  end

  defp attempt_metadata(context, response) do
    response
    |> Metadata.response_metadata(@error_kind, context.request_options)
    |> Map.put("auth_refresh_trigger", AuthRefresh.trigger_kind(:http))
  end

  defp unauthorized_code, do: ErrorCodes.upstream_unauthorized_code()

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
