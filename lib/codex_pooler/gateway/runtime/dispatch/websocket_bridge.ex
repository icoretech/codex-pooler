defmodule CodexPooler.Gateway.Runtime.Dispatch.WebsocketBridge do
  @moduledoc """
  Dispatches a downstream HTTP SSE turn upstream over the session's Codex
  websocket owner connection to reuse the provider prompt cache.

  Opt-in per Pool (`upstream_websocket_bridge_enabled`) and bounded to public
  OpenAI-compatible streaming turns whose continuity session is unpinned or
  pinned to the selected assignment. The upstream payload is rebuilt with the
  same normalizer pipeline the native websocket path uses, then submitted
  through the owner-session machinery; the resulting event stream feeds the
  unchanged HTTP SSE relay via `WebsocketBridgeStream`. Every failure before
  the first upstream event falls back to plain HTTP dispatch on the same
  candidate and attempt.
  """

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.Request, as: DispatchRequest
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.RouteClass

  @preflight_timeout_ms 15_000

  @type dispatch_fun :: (Req.Response.t(), PreparedContext.t() -> term())

  @spec eligible?(PreparedContext.t()) :: boolean()
  def eligible?(%PreparedContext{context: context}) do
    opts = context.request_options
    settings = context.route_state && context.route_state.routing_settings

    bridge_enabled?(settings) and
      opts.transport.transport == "http_sse" and
      is_nil(opts.transport.websocket_writer) and
      opts.openai_compatibility.public_openai_responses_stream == true and
      RouteClass.streaming?(context.payload) and
      Websocket.websocket_owner_forwarding_enabled?() and
      session_assignment_ok?(opts.continuity.codex_session, context.assignment)
  end

  defp bridge_enabled?(%{upstream_websocket_bridge_enabled: true}), do: true
  defp bridge_enabled?(_settings), do: false

  defp session_assignment_ok?(%CodexSession{pool_upstream_assignment_id: nil}, _assignment),
    do: true

  defp session_assignment_ok?(
         %CodexSession{pool_upstream_assignment_id: assignment_id},
         %{id: assignment_id}
       ),
       do: true

  defp session_assignment_ok?(_session, _assignment), do: false

  @doc """
  Runs the bridged turn. Returns `{:ok, prepared_context, response}` once the
  first upstream event arrived and the fabricated SSE response is ready for
  the standard HTTP finalization path, or `{:fallback, reason}` when anything
  failed before the first upstream event.
  """
  @spec open(PreparedContext.t()) ::
          {:ok, PreparedContext.t(), Req.Response.t()} | {:fallback, term()}
  def open(%PreparedContext{context: context} = prepared_context) do
    correlation_id = Ecto.UUID.generate()
    stream = WebsocketBridgeStream.start(correlation_id)

    with {:ok, runtime} <-
           Websocket.prepare_owner_bridge_session(
             context.auth,
             context.request_options,
             %{pid: stream.relay, correlation_id: correlation_id}
           ),
         {:ok, ws_payload, bridged_options} <- bridge_payload(prepared_context, runtime) do
      dispatch_request = bridge_dispatch_request(prepared_context, ws_payload, bridged_options)

      WebsocketBridgeStream.arm(
        stream,
        downstream_epoch(runtime),
        fn -> UpstreamDispatch.websocket_request(dispatch_request) end
      )

      await_first_event(prepared_context, stream, bridged_options)
    else
      {:error, reason} ->
        WebsocketBridgeStream.cancel(stream)
        {:fallback, reason}
    end
  end

  # The relay reports its decision out of band as {:preflight, decision}. Only a
  # data frame commits to websocket streaming; a completion, error, or timeout
  # before the first data frame falls back to HTTP. The real stream parts are
  # left untouched in the mailbox so StreamRelay consumes them in order.
  defp await_first_event(prepared_context, %WebsocketBridgeStream{ref: ref} = stream, options) do
    receive do
      {^ref, {:preflight, :stream}} ->
        prepared_context = mark_bridged_attempt(prepared_context)
        {:ok, put_bridged_options(prepared_context, options), bridge_response(stream)}

      {^ref, {:preflight, {:fallback, reason}}} ->
        WebsocketBridgeStream.cancel(stream)
        {:fallback, reason}
    after
      @preflight_timeout_ms ->
        WebsocketBridgeStream.cancel(stream)
        {:fallback, :bridge_preflight_timeout}
    end
  end

  # The canonical attempt row records the upstream transport that actually
  # carried the turn; the request keeps the downstream protocol.
  defp mark_bridged_attempt(
         %PreparedContext{context: %{attempt: %Attempt{} = attempt} = context} = prepared_context
       ) do
    case Accounting.mark_attempt_upstream_transport(attempt, "websocket") do
      {:ok, updated_attempt} ->
        %{prepared_context | context: %{context | attempt: updated_attempt}}

      {:error, _changeset} ->
        prepared_context
    end
  end

  defp mark_bridged_attempt(%PreparedContext{} = prepared_context), do: prepared_context

  defp bridge_response(%WebsocketBridgeStream{} = stream) do
    %Req.Response{
      status: 200,
      headers: %{"content-type" => ["text/event-stream"]},
      body: stream
    }
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
             ws_options
           ) do
      {ws_payload, ws_options} =
        RequestCompression.maybe_compress(ws_payload, context, ws_options)

      bridged_options =
        context.request_options
        |> Websocket.bridge_owner_request_options(runtime)
        |> carry_payload_compression(ws_options)

      {:ok, ws_payload, bridged_options}
    end
  end

  # The compression pass records safe accounting metadata on the runtime
  # context of the options it compressed; carry it onto the bridged options so
  # bridged attempts keep the same payload_compression metadata as HTTP.
  defp carry_payload_compression(bridged_options, %RequestOptions{
         runtime: %{payload_compression: metadata}
       })
       when not is_nil(metadata) do
    RequestOptions.put_runtime_context(bridged_options, payload_compression: metadata)
  end

  defp carry_payload_compression(bridged_options, _ws_options), do: bridged_options

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
      accounting_request: context.reserved.request,
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
