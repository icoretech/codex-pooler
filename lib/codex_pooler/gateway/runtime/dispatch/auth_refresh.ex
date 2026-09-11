defmodule CodexPooler.Gateway.Runtime.Dispatch.AuthRefresh do
  @moduledoc false

  # Transport-neutral one-shot upstream credential refresh shared by the HTTP
  # and websocket attempt paths so credential-epoch fencing, request metadata,
  # suppression rules, and the bounded log receipt cannot drift between them.

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  @access_token_secret_kind "access_token"
  @http_trigger_kind "http_upstream_auth_failure"
  @websocket_trigger_kind "websocket_terminal_auth_failure"
  @outcome_pattern ~r/\A[A-Za-z0-9_.-]{1,80}\z/

  @type transport :: :http | :websocket
  @type metadata :: %{required(String.t()) => String.t() | integer()}
  @type refresh_result ::
          {:ok, metadata(), UpstreamIdentity.t()} | {:refresh_not_retryable, metadata()}

  @spec trigger_kind(transport()) :: String.t()
  def trigger_kind(:http), do: @http_trigger_kind
  def trigger_kind(:websocket), do: @websocket_trigger_kind

  # The 401 was produced by the credentials this dispatch connected with:
  # carrying their epoch lets a late follower skip the provider refresh when
  # another caller already rotated, and retry with the returned identity.
  # At token expiry every in-flight request on the identity fails auth at
  # once, so this is the highest-frequency duplicate-refresh source.
  @spec refresh(SelectedCandidateContext.t(), transport()) :: refresh_result()
  def refresh(%SelectedCandidateContext{identity: identity} = context, transport) do
    trigger_kind = trigger_kind(transport)

    result =
      identity
      |> TokenRefresh.refresh_access_token(
        trigger_kind: trigger_kind,
        expected_credential_epoch: CredentialFencing.credential_epoch(identity)
      )
      |> classify(trigger_kind)

    log_refresh(transport, result, context)
    result
  end

  @spec record_metadata(SelectedCandidateContext.t(), metadata(), atom()) ::
          {:ok, SelectedCandidateContext.t()} | {:error, map()}
  def record_metadata(%SelectedCandidateContext{} = context, metadata, operation)
      when is_atom(operation) do
    case Accounting.merge_request_metadata(context.reserved.request, %{"auth_refresh" => metadata}) do
      {:ok, request} ->
        {:ok, %{context | reserved: %{context.reserved | request: request}}}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          operation,
          context.reserved.request,
          context.attempt,
          reason
        )
    end
  end

  @spec decrypt_access_token(UpstreamIdentity.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt_access_token(%UpstreamIdentity{} = identity),
    do: Secrets.decrypt_active_secret(identity, @access_token_secret_kind)

  @spec retry_suppressed?(SelectedCandidateContext.t()) :: boolean()
  def retry_suppressed?(%SelectedCandidateContext{} = context) do
    bound_reset_probe?(context) or
      RequestOptions.connection_bound_compaction?(context.request_options) or
      match?(%ClientRetry.DispatchAuthority{}, context.client_retry_dispatch_authority)
  end

  @spec bound_reset_probe?(SelectedCandidateContext.t()) :: boolean()
  def bound_reset_probe?(%SelectedCandidateContext{} = context) do
    case context.request_options.routing.reset_probe do
      %ResetProbe{} = probe ->
        ResetProbe.matches?(
          probe,
          context.assignment.id,
          context.identity.id,
          context.request_options.routing.effective_model || context.model.exposed_model_id,
          context.route_class
        )

      nil ->
        false
    end
  end

  defp classify({:ok, %{status: :active, identity: refreshed_identity}}, trigger_kind) do
    {:ok, %{"status" => "succeeded", "trigger_kind" => trigger_kind}, refreshed_identity}
  end

  defp classify({:ok, result}, trigger_kind) do
    {:refresh_not_retryable,
     %{"status" => to_string(result.status), "trigger_kind" => trigger_kind}}
  end

  defp classify({:error, :refresh_in_progress, metadata}, trigger_kind) do
    {:refresh_not_retryable,
     metadata
     |> refresh_in_progress_metadata()
     |> Map.put("trigger_kind", trigger_kind)}
  end

  defp classify({:error, reason}, trigger_kind) do
    {:refresh_not_retryable,
     %{
       "status" => "failed",
       "trigger_kind" => trigger_kind,
       "reason" => safe_refresh_reason(reason)
     }}
  end

  # One bounded receipt per provider refresh attempt: fixed outcome vocabulary
  # plus trusted internal correlators only, never tokens, bodies, or provider ids.
  defp log_refresh(transport, result, %SelectedCandidateContext{} = context) do
    Logger.info(fn ->
      "upstream auth refresh transport=#{transport} outcome=#{safe_outcome(result)} " <>
        "request_id=#{context.reserved.request.id} identity=#{context.identity.id}"
    end)
  end

  defp safe_outcome({:ok, %{"status" => status}, _identity}), do: safe_token(status)
  defp safe_outcome({:refresh_not_retryable, %{"status" => status}}), do: safe_token(status)
  defp safe_outcome(_result), do: "unknown"

  defp safe_token(value) when is_binary(value) do
    if Regex.match?(@outcome_pattern, value), do: value, else: "unknown"
  end

  defp safe_token(_value), do: "unknown"

  defp refresh_in_progress_metadata(metadata) when is_map(metadata) do
    %{"status" => "refresh_in_progress"}
    |> maybe_put_safe_metadata("attempt_id", metadata[:attempt_id])
    |> maybe_put_safe_metadata("generation", metadata[:generation])
    |> maybe_put_safe_metadata("started_at", metadata[:started_at])
    |> maybe_put_safe_metadata("stale_after_ms", metadata[:stale_after_ms])
  end

  defp maybe_put_safe_metadata(attrs, key, value) when is_binary(value) or is_integer(value),
    do: Map.put(attrs, key, value)

  defp maybe_put_safe_metadata(attrs, _key, _value), do: attrs

  defp safe_refresh_reason(%{code: code}), do: to_string(code)
  defp safe_refresh_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_refresh_reason(_reason), do: "token_refresh_failed"
end
