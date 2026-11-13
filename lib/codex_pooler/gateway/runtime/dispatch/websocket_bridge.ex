defmodule CodexPooler.Gateway.Runtime.Dispatch.WebsocketBridge do
  @moduledoc """
  Dispatches a downstream HTTP SSE turn upstream over the session's Codex
  websocket owner connection to reuse the provider prompt cache.

  Bounded to public OpenAI-compatible streaming turns whose continuity session
  is unpinned or pinned to the selected assignment. The upstream payload is
  rebuilt with the same normalizer pipeline the native websocket path uses,
  then submitted through the owner-session machinery; the resulting event
  stream feeds the unchanged HTTP SSE relay via `WebsocketBridgeStream`. The
  relay decides commitment (first client-rendered content, bounded buffer
  caps, or its pre-content deadline). After submission, ambiguous owner or
  transport failures stay on the websocket attempt without hidden HTTP
  resubmission. This module's preflight timeout also fails closed on the
  websocket attempt: silence cannot prove that the provider rejected the
  submission.
  """

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.OpenAICompatibility.DeploymentPolicyDenial
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Transports.ProviderCreditsAdmission
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.Request, as: DispatchRequest
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.RouteClass

  @default_preflight_timeout_ms 15_000

  @doc "Captures candidate-scoped upstream intent without changing downstream HTTP transport or granting a send receipt."
  @spec plan(RequestOptions.t(), map()) :: RequestOptions.t()
  def plan(%RequestOptions{} = options, payload) when is_map(payload) do
    RequestOptions.put_transport(options, upstream_websocket_bridge_plan: bridge_plan(options, payload))
  end

  @spec eligible?(PreparedContext.t()) :: boolean()
  def eligible?(%PreparedContext{context: context}) do
    plan = bridge_plan(context.request_options, context.payload)
    plan == :all or plan == context.assignment.id
  end

  # Both the early quota scope and the selected physical attempt use this same
  # predicate. Opening the owner still rechecks the live forwarding/session state.
  @spec bridge_plan(RequestOptions.t(), map()) :: CodexPooler.Gateway.Payloads.RequestOptions.Transport.bridge_plan()
  defp bridge_plan(options, payload) do
    if options.transport.transport == "http_sse" and
         options.transport.route_class == RouteClass.proxy_stream() and
         is_nil(options.transport.websocket_writer) and
         options.openai_compatibility.public_openai_responses_stream == true and
         RouteClass.streaming?(payload) and
         Websocket.websocket_owner_forwarding_enabled?() do
      session_bridge_plan(options.continuity.codex_session)
    else
      nil
    end
  end

  defp session_bridge_plan(%CodexSession{pool_upstream_assignment_id: nil}), do: :all
  defp session_bridge_plan(%CodexSession{pool_upstream_assignment_id: assignment_id}) when is_binary(assignment_id), do: assignment_id
  defp session_bridge_plan(_session), do: nil

  @doc """
  Runs the bridged turn. Returns `{:ok, prepared_context, response}` once the
  first upstream event arrived and the fabricated SSE response is ready for
  the standard HTTP finalization path, or `{:fallback, reason}` only when the
  relay has positive proof that failure happened before upstream submission.
  """
  @spec open(PreparedContext.t()) ::
          {:ok, PreparedContext.t(), Req.Response.t()}
          | {:fallback, term()}
          | {:error, CodexPooler.Gateway.Transports.ProviderCreditsAdmission.denial()}
          | {:error, :owner_unavailable}
  def open(%PreparedContext{context: context} = prepared_context) do
    correlation_id = Ecto.UUID.generate()

    stream =
      WebsocketBridgeStream.start(correlation_id,
        preflight_timeout_ms: preflight_timeout_ms()
      )

    with {:ok, runtime} <-
           Websocket.prepare_owner_bridge_session(
             context.auth,
             context.request_options,
             %{pid: stream.relay, correlation_id: correlation_id}
           ),
         {:ok, ws_payload, bridged_options} <- bridge_payload(prepared_context, runtime),
         {:bound, {:ok, binding}} <-
           {:bound,
            Accounting.bind_websocket_owner_bridge(
              context.auth,
              context.reserved.request,
              context.attempt,
              bridged_options
            )} do
      prepared_context = %{
        prepared_context
        | context: %{
            context
            | reserved: %{context.reserved | request: binding.request},
              attempt: binding.attempt
          }
      }

      dispatch_request = bridge_dispatch_request(prepared_context, ws_payload, bridged_options)

      WebsocketBridgeStream.arm(
        stream,
        downstream_epoch(runtime),
        fn -> UpstreamDispatch.websocket_request(dispatch_request) end
      )

      await_first_event(prepared_context, stream, bridged_options)
    else
      {:bound, {:error, _reason}} ->
        WebsocketBridgeStream.cancel(stream)
        {:error, :owner_unavailable}

      {:error, reason} ->
        WebsocketBridgeStream.cancel(stream)
        {:fallback, reason}
    end
  end

  # The relay reports its decision out of band as {:preflight, decision}. Only a
  # data frame commits to websocket streaming. Fallback requires a positive
  # pre-submission receipt; ambiguous completion, error, or timeout commits a
  # failed websocket attempt. Real stream parts stay in the mailbox so
  # StreamRelay consumes them in order.
  defp await_first_event(prepared_context, %WebsocketBridgeStream{ref: ref} = stream, options) do
    monitor_ref = Process.monitor(stream.relay)

    receive do
      {^ref, {:preflight, :stream}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, put_bridged_options(prepared_context, options), bridge_response(stream)}

      {^ref, {:preflight, {:rejected, status, body}}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, put_bridged_options(prepared_context, options), rejection_response(stream, status, body)}

      # A provider usage limit before output (findings#206 row 206-582): the
      # same `429` the provider answers over HTTP, with the frame's sanitized
      # headers, so the HTTP finalization fails over or answers the terminal
      # usage limit exactly as it does for that response.
      {^ref, {:preflight, {:rejected, status, body, headers}}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, put_bridged_options(prepared_context, options), rejection_response(stream, status, body, headers)}

      {^ref, {:preflight, {:policy_denied, denial}}} ->
        Process.demonitor(monitor_ref, [:flush])
        WebsocketBridgeStream.cancel(stream)
        {:error, denial}

      {^ref, {:preflight, {:fallback, reason}}} ->
        Process.demonitor(monitor_ref, [:flush])
        WebsocketBridgeStream.cancel(stream)

        case restore_http_fallback(prepared_context, options) do
          :ok -> {:fallback, reason}
          {:error, _restore_reason} -> {:error, :owner_unavailable}
        end

      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        {:error, :owner_unavailable}
    end
  end

  defp preflight_timeout_ms do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:preflight_timeout_ms, @default_preflight_timeout_ms)
  end

  defp restore_http_fallback(
         %PreparedContext{context: %{auth: auth, reserved: reserved, attempt: attempt}},
         options
       ) do
    case Accounting.restore_websocket_owner_http_fallback(
           auth,
           reserved.request,
           attempt,
           options
         ) do
      {:ok, _binding} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bridge_response(%WebsocketBridgeStream{} = stream) do
    %Req.Response{
      status: 200,
      headers: %{"content-type" => ["text/event-stream"]},
      body: stream
    }
  end

  # A provider refusal sent as a wrapped websocket error frame before any
  # content becomes the HTTP response the provider returns for the same
  # request over HTTP, so the standard finalization answers the public client
  # with the same status and error body and records the same rejection fields
  # (findings#225). Taking the relay's metadata reaps it and its submit task.
  # The connection-bound guard answers an anchor its fresh connection cannot
  # resolve with that same refusal before sending anything (findings#232 row
  # 232-277); its exact metadata goes along as the proof that the provider
  # never received the request.
  defp rejection_response(%WebsocketBridgeStream{} = stream, status, body, headers \\ []) do
    %{upstream_websocket_connection: connection} =
      metadata = WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream)

    response_headers = Enum.reduce(headers, %{"content-type" => ["application/json"]}, fn {name, value}, acc -> Map.put_new(acc, name, [value]) end)

    %Req.Response{status: status, headers: response_headers, body: body}
    |> Req.Response.put_private(:upstream_websocket_connection, connection)
    |> Req.Response.put_private(:transport_failure, TransportFailureReason.sanitize_continuation_generation_guard_metadata(metadata.transport_failure))
    |> DeploymentPolicyDenial.mark_bridge_rejection()
  end

  defp put_bridged_options(%PreparedContext{context: context} = prepared_context, options) do
    %{prepared_context | context: %{context | request_options: options}}
  end

  # Rebuild the upstream payload exactly as the native websocket path would:
  # the websocket normalizer clause owns the response.create envelope and the
  # websocket-specific input, reasoning, and responses-lite normalization.
  defp bridge_payload(%PreparedContext{context: context}, runtime) do
    ws_options = RequestOptions.for_websocket(context.request_options)

    with {:ok, ws_payload, ws_options} <-
           PayloadNormalizer.prepare_upstream_payload(
             context.payload,
             context.model,
             context.endpoint,
             ws_options,
             assignment_id: context.assignment.id
           ) do
      bridged_options =
        context.request_options
        |> Websocket.bridge_owner_request_options(runtime)
        |> carry_serialization_runtime_context(ws_options)

      {:ok, ws_payload, bridged_options}
    end
  end

  # The second serialization owns attempt-local runtime metadata. Carry its
  # values onto the bridged HTTP options so stale first-pass state is replaced.
  defp carry_serialization_runtime_context(bridged_options, %RequestOptions{
         runtime: runtime
       }) do
    updates = [
      prompt_cache_controls_downgraded: runtime.prompt_cache_controls_downgraded
    ]

    RequestOptions.put_runtime_context(bridged_options, updates)
  end

  defp bridge_dispatch_request(
         %PreparedContext{context: context} = prepared_context,
         ws_payload,
         %RequestOptions{} = bridged_options
       ) do
    %DispatchRequest{
      url: prepared_context.url,
      token: prepared_context.token,
      upstream_payload: ws_payload,
      original_payload: nil,
      identity: context.identity,
      provider_credits_context: ProviderCreditsAdmission.from_selected(context, bridged_options),
      routing_hint_authorized?: prepared_context.routing_hint_authorized?,
      accounting_request: context.reserved.request,
      accounting_attempt: context.attempt,
      writer: nil,
      assignment_advertised?: assignment_advertised?(context),
      request_options: bridged_options
    }
  end

  defp assignment_advertised?(context) do
    ModelMetadata.assignment_source?(context.model, context.assignment.id)
  end

  defp downstream_epoch(%{websocket_owner_downstream: %{epoch: epoch}}) when is_integer(epoch),
    do: epoch

  @spec log_fallback(PreparedContext.t(), term()) :: :ok
  def log_fallback(%PreparedContext{context: context}, reason) do
    Logger.info(
      "upstream websocket bridge fell back to http " <>
        "reason=#{safe_reason(reason)} " <>
        "request_id=#{context.reserved.request.id} " <>
        "assignment_id=#{context.assignment.id}"
    )
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "bridge_error"
end
