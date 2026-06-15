defmodule CodexPooler.Gateway.Runtime.Dispatch.CandidateDispatch do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Secrets

  @secret_kind "access_token"
  @type dispatch_candidate :: (PreparedContext.t() -> dispatch_candidate_result())
  @type dispatch_candidate_result :: Dispatch.dispatch_result()
  @type dispatch_result :: {:ok, GatewayContracts.gateway_result()} | {:error, map()}

  @spec dispatch(map(), dispatch_candidate()) :: dispatch_result()
  def dispatch(attrs, dispatch_fun) when is_function(dispatch_fun, 1) do
    Dispatch.dispatch(attrs, &decrypt_and_dispatch_candidate(&1, dispatch_fun))
  end

  @spec dispatch_from(
          Context.t(),
          non_neg_integer(),
          dispatch_candidate()
        ) :: dispatch_candidate_result()
  def dispatch_from(context, start_index, dispatch_fun)
      when is_integer(start_index) and is_function(dispatch_fun, 1) do
    Dispatch.dispatch_from(
      context,
      start_index,
      &decrypt_and_dispatch_candidate(&1, dispatch_fun)
    )
  end

  defp decrypt_and_dispatch_candidate(%Context{} = context, dispatch_fun) do
    with {:ok, token} <-
           Secrets.decrypt_active_secret(context.identity, @secret_kind),
         {:ok, url} <-
           upstream_url(
             context.identity,
             context.assignment,
             context.request_options.transport.upstream_endpoint
           ),
         {:ok, upstream_payload, request_options} <-
           PayloadNormalizer.prepare_upstream_payload(
             context.payload,
             context.model,
             context.endpoint,
             context.request_options
           ) do
      context = %{context | request_options: request_options}

      {upstream_payload, request_options} =
        RequestCompression.maybe_compress(upstream_payload, context, request_options)

      context = %{context | request_options: request_options}

      dispatch_fun.(%PreparedContext{
        context: context,
        token: token,
        url: url,
        upstream_payload: upstream_payload
      })
    else
      {:error, reason} ->
        Finalization.handle_dispatch_error(reason, context, elapsed_ms(context.started))
    end
  end

  defp upstream_url(identity, assignment, endpoint) do
    EndpointMetadata.endpoint_url(identity, assignment, endpoint)
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
