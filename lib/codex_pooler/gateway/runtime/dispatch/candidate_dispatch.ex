defmodule CodexPooler.Gateway.Runtime.Dispatch.CandidateDispatch do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.SettlementAttrs
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Upstreams.ResponsesAPICompaction
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  require Logger

  @secret_kind "access_token"
  @websocket_responses_lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"
  @type dispatch_candidate :: (PreparedContext.t() -> dispatch_candidate_result())
  @type dispatch_candidate_result :: Dispatch.dispatch_result()
  @type dispatch_result :: {:ok, GatewayContracts.gateway_result()} | {:error, map()}

  defmodule Operations do
    @moduledoc false

    alias CodexPooler.Accounting
    alias CodexPooler.Accounting.FailureResponse
    alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness
    alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
    alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement
    alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
    alias CodexPooler.Upstreams.EndpointMetadata
    alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
    alias CodexPooler.Upstreams.Secrets

    @type merge_request_metadata :: (Accounting.Request.t(), map() ->
                                       {:ok, Accounting.Request.t()} | {:error, term()})
    @type decrypt_active_secret :: (UpstreamIdentity.t(), String.t() ->
                                      {:ok, binary()} | {:error, term()})
    @type upstream_url :: (UpstreamIdentity.t(), PoolUpstreamAssignment.t(), String.t() ->
                             {:ok, String.t()} | {:error, term()})
    @type owner_witness :: OwnerWitness.t() | nil
    @type finalize_failure :: (Accounting.Request.t(),
                               Accounting.Attempt.t(),
                               map(),
                               owner_witness() ->
                                 term())
    @type neutral_completion :: (SelectedCandidateContext.t() -> term())
    @type accounting_failure :: (atom(), Accounting.Request.t(), Accounting.Attempt.t(), term() ->
                                   {:error, map()})

    @enforce_keys [
      :merge_request_metadata,
      :decrypt_active_secret,
      :upstream_url,
      :finalize_failure,
      :neutral_completion,
      :accounting_failure
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            merge_request_metadata: merge_request_metadata(),
            decrypt_active_secret: decrypt_active_secret(),
            upstream_url: upstream_url(),
            finalize_failure: finalize_failure(),
            neutral_completion: neutral_completion(),
            accounting_failure: accounting_failure()
          }

    @spec defaults() :: t()
    def defaults do
      %__MODULE__{
        merge_request_metadata: &Accounting.merge_request_metadata/2,
        decrypt_active_secret: &Secrets.decrypt_active_secret/2,
        upstream_url: &EndpointMetadata.endpoint_url/3,
        finalize_failure: &AttemptSettlement.finalize_failure/4,
        neutral_completion: &DispatchLifecycle.neutral_completion/1,
        accounting_failure: &FailureResponse.accounting_failure/4
      }
    end

    @spec build(t() | map()) :: t()
    def build(%__MODULE__{} = operations), do: operations

    def build(overrides) when is_map(overrides) do
      overrides =
        case Map.fetch(overrides, :finalize_failure) do
          {:ok, callback} when is_function(callback, 3) ->
            Map.put(overrides, :finalize_failure, fn request, attempt, attrs, _owner_witness ->
              callback.(request, attempt, attrs)
            end)

          _other ->
            overrides
        end

      struct!(defaults(), overrides)
    end
  end

  @spec dispatch(Context.t(), dispatch_candidate()) :: dispatch_result()
  def dispatch(%Context{} = context, dispatch_fun) when is_function(dispatch_fun, 1) do
    dispatch_with_operations(context, dispatch_fun, Operations.defaults())
  end

  @doc false
  @spec dispatch_with_operations(
          Context.t(),
          dispatch_candidate(),
          Operations.t() | map()
        ) :: dispatch_result()
  def dispatch_with_operations(%Context{} = context, dispatch_fun, operations)
      when is_function(dispatch_fun, 1) and is_map(operations) do
    operations = Operations.build(operations)
    Dispatch.dispatch(context, &decrypt_and_dispatch_candidate(&1, dispatch_fun, operations))
  end

  @spec dispatch_from(
          SelectedCandidateContext.t(),
          non_neg_integer(),
          dispatch_candidate()
        ) :: dispatch_candidate_result()
  def dispatch_from(context, start_index, dispatch_fun)
      when is_integer(start_index) and is_function(dispatch_fun, 1) do
    operations = Operations.defaults()

    Dispatch.dispatch_from(
      context,
      start_index,
      &decrypt_and_dispatch_candidate(&1, dispatch_fun, operations)
    )
  end

  @spec dispatch_selected(SelectedCandidateContext.t(), dispatch_candidate()) ::
          dispatch_candidate_result()
  def dispatch_selected(%SelectedCandidateContext{} = context, dispatch_fun)
      when is_function(dispatch_fun, 1) do
    decrypt_and_dispatch_candidate(context, dispatch_fun, Operations.defaults())
  end

  defp decrypt_and_dispatch_candidate(
         %SelectedCandidateContext{} = context,
         dispatch_fun,
         %Operations{} = operations
       ) do
    with {:ok, upstream_payload, request_options} <-
           PayloadNormalizer.prepare_upstream_payload(
             context.payload,
             context.model,
             context.endpoint,
             context.request_options
           ),
         {:ok, context} <- persist_compaction_projection(context, request_options, operations),
         {:ok, token} <-
           operations.decrypt_active_secret.(context.identity, @secret_kind),
         {:ok, url} <-
           operations.upstream_url.(
             context.identity,
             context.assignment,
             context.request_options.transport.upstream_endpoint
           ),
         {:ok, upstream_payload, context} <-
           ResponsesAPICompaction.prepare(upstream_payload, context) do
      request_options = context.request_options

      {upstream_payload, request_options} =
        RequestCompression.maybe_compress(upstream_payload, context, request_options)

      context = %{context | request_options: request_options}
      log_compact_final_egress(context, upstream_payload)

      %PreparedContext{
        context: context,
        token: token,
        url: url,
        upstream_payload: upstream_payload,
        routing_hint_authorized?: UpstreamIdentity.authenticated_codex_chatgpt?(context.identity)
      }
      |> dispatch_fun.()
      |> log_compact_transport_failure(context)
    else
      {:compaction_projection_merge_error, reason} ->
        handle_compaction_projection_merge_failure(context, reason, operations)

      {:error, reason} ->
        result = Finalization.handle_dispatch_error(reason, context, elapsed_ms(context.started))
        log_compact_terminal_decision(context, :local_preflight, result, reason)
        result
    end
  end

  defp log_compact_transport_failure(
         {:error, %{code: "upstream_request_failed"}} = result,
         context
       ) do
    log_compact_terminal_decision(context, :transport_failure, result, :transport_failure)
    result
  end

  defp log_compact_transport_failure(result, _context), do: result

  defp log_compact_terminal_decision(
         %SelectedCandidateContext{
           request_options:
             %{payload_context: %{compaction_trigger_bridge?: true}} = request_options
         } = context,
         source_stage,
         {:error, error},
         reason
       )
       when source_stage in [:local_preflight, :transport_failure] and is_map(error) do
    {param_state, param} = compact_terminal_param(error)

    Logger.warning(fn ->
      "compact terminal decision " <>
        "source_stage=#{source_stage} " <>
        "code=#{DiagnosticTaxonomy.identifier(Map.get(error, :code)) || "unknown"} " <>
        "status=#{compact_terminal_status(error)} " <>
        "terminal_type=#{compact_terminal_type(source_stage)} " <>
        "reason_code=#{DiagnosticTaxonomy.identifier(reason) || DiagnosticTaxonomy.identifier(Map.get(error, :code)) || "unknown"} " <>
        "param_state=#{param_state}" <>
        if(is_nil(param), do: "", else: " param=#{param}") <>
        " elapsed_ms=#{elapsed_ms(context.started)} " <>
        "request_id=#{DiagnosticTaxonomy.safe_correlator(context.reserved.request.id)} " <>
        "attempt_id=#{DiagnosticTaxonomy.safe_correlator(context.attempt.id)} " <>
        "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(compact_session_id(request_options))}"
    end)
  end

  defp log_compact_terminal_decision(_context, _source_stage, _result, _reason), do: :ok

  defp compact_terminal_status(%{status: status}) when is_integer(status), do: status
  defp compact_terminal_status(_error), do: "unknown"

  defp compact_terminal_type(:local_preflight), do: "dispatch_error"
  defp compact_terminal_type(:transport_failure), do: "transport_failure"

  defp compact_terminal_param(error) do
    case Map.fetch(error, :param) do
      {:ok, nil} ->
        {"absent", nil}

      {:ok, param} ->
        case UpstreamErrorParam.sanitize(param) do
          value when is_binary(value) -> {"accepted", value}
          nil -> {"rejected", nil}
        end

      :error ->
        {"absent", nil}
    end
  end

  defp log_compact_final_egress(
         %SelectedCandidateContext{
           request_options:
             %{
               payload_context: %{compaction_trigger_bridge?: true}
             } = request_options
         } = context,
         upstream_payload
       )
       when is_binary(upstream_payload) do
    case CodexPooler.JSON.decode(upstream_payload) do
      {:ok, %{} = payload} ->
        marker = get_in(payload, ["client_metadata", @websocket_responses_lite_marker])
        serving_mode = request_options.routing.model_serving_mode || "full"
        transport = request_options.transport.transport

        Logger.info(fn ->
          "compact final egress decision " <>
            "request_id=#{DiagnosticTaxonomy.safe_correlator(context.reserved.request.id)} " <>
            "attempt_id=#{DiagnosticTaxonomy.safe_correlator(context.attempt.id)} " <>
            "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(compact_session_id(request_options))} " <>
            "discriminator_class=#{compact_discriminator_class(payload)} " <>
            "serving_mode=#{serving_mode} " <>
            "lite_marker_present=#{is_binary(marker)} " <>
            "lite_marker_matches=#{compact_lite_marker_matches?(marker, serving_mode, transport)} " <>
            "input_mode=#{compact_input_mode(request_options)} " <>
            "anchor_present=#{not is_nil(request_options.continuity.previous_response_id)} " <>
            "transport=#{DiagnosticTaxonomy.safe_correlator(transport)}" <>
            compact_lifecycle_metadata(request_options)
        end)

      _invalid ->
        :ok
    end
  end

  defp log_compact_final_egress(%SelectedCandidateContext{}, _upstream_payload), do: :ok

  defp compact_discriminator_class(%{"type" => "response.create"}), do: "response_create"

  defp compact_discriminator_class(%{} = payload) when not is_map_key(payload, "type"),
    do: "missing"

  defp compact_discriminator_class(%{}), do: "other"

  defp compact_lite_marker_matches?(marker, "lite", "websocket"), do: marker == "true"
  defp compact_lite_marker_matches?(marker, "full", "websocket"), do: is_nil(marker)
  defp compact_lite_marker_matches?(marker, _serving_mode, _transport), do: is_nil(marker)

  defp compact_input_mode(%{payload_context: %{compaction_input_mode: mode}})
       when mode in [:incremental, :full_history],
       do: Atom.to_string(mode)

  defp compact_input_mode(_request_options), do: "other"

  defp compact_session_id(%{continuity: %{codex_session: %{id: id}}}) when is_binary(id), do: id
  defp compact_session_id(_request_options), do: nil

  defp compact_lifecycle_metadata(%{native_compaction_admission: admission})
       when is_struct(admission) do
    lifecycle = Map.get(admission, :expected_connection_lifecycle, %{})
    " generation=#{Map.get(lifecycle, :generation, "none")}" <> compact_owner_epoch(admission)
  end

  defp compact_lifecycle_metadata(_request_options), do: " generation=none owner_epoch=none"

  defp compact_owner_epoch(%{owner: {:forwarded, _session, _lease, downstream, _opts}})
       when is_map(downstream) do
    " owner_epoch=#{Map.get(downstream, :epoch, "none")}"
  end

  defp compact_owner_epoch(_admission), do: " owner_epoch=none"

  defp persist_compaction_projection(
         %SelectedCandidateContext{} = context,
         %{payload_context: %{compaction_trigger_bridge?: true, compaction_projection: safe_map}} =
           request_options,
         %Operations{} = operations
       )
       when is_map(safe_map) do
    case operations.merge_request_metadata.(context.reserved.request, %{
           "compaction_projection" => safe_map
         }) do
      {:ok, request} ->
        {:ok,
         %{
           context
           | request_options: request_options,
             reserved: %{context.reserved | request: request}
         }}

      {:error, reason} ->
        {:compaction_projection_merge_error, reason}
    end
  end

  defp persist_compaction_projection(
         %SelectedCandidateContext{
           request_options: %{payload_context: %{compaction_trigger_bridge?: true}}
         },
         _request_options,
         %Operations{}
       ) do
    {:compaction_projection_merge_error, :missing_compaction_projection}
  end

  defp persist_compaction_projection(
         %SelectedCandidateContext{} = context,
         request_options,
         %Operations{}
       ) do
    {:ok, %{context | request_options: request_options}}
  end

  defp handle_compaction_projection_merge_failure(
         context,
         merge_reason,
         %Operations{} = operations
       ) do
    request = context.reserved.request

    cleanup_result =
      run_compaction_projection_cleanup(
        fn ->
          operations.finalize_failure.(
            request,
            context.attempt,
            SettlementAttrs.failure(
              context,
              500,
              "gateway_accounting_failed",
              "gateway accounting finalization failed",
              %{},
              latency_ms: elapsed_ms(context.started)
            ),
            context.request_options.runtime.session_owner_witness
          )
        end,
        fn -> operations.neutral_completion.(context) end,
        merge_reason
      )

    case cleanup_result do
      {:accounting_failure, operation, reason} ->
        operations.accounting_failure.(
          operation,
          request,
          context.attempt,
          reason
        )

      {:error, _gateway_error} = error ->
        error
    end
  end

  @doc false
  @spec run_compaction_projection_cleanup((-> term()), (-> term()), term()) ::
          {:error, term()} | {:accounting_failure, atom(), term()}
  def run_compaction_projection_cleanup(settlement_fun, neutral_fun, merge_reason)
      when is_function(settlement_fun, 0) and is_function(neutral_fun, 0) do
    settlement_result = settlement_fun.()
    neutral_result = neutral_fun.()
    compaction_projection_cleanup_result(settlement_result, neutral_result, merge_reason)
  end

  @doc false
  @spec compaction_projection_cleanup_result(term(), term(), term()) ::
          {:error, term()} | {:accounting_failure, atom(), term()}
  def compaction_projection_cleanup_result(settlement_result, neutral_result, merge_reason) do
    case {settlement_result, neutral_result} do
      {{:ok, _settled}, :ok} ->
        {:accounting_failure, :merge_compaction_projection_metadata, merge_reason}

      {{:error, settlement_error}, :ok} ->
        {:error, settlement_error}

      {{:ok, _settled}, {:error, neutral_error}} ->
        {:error, neutral_error}

      {{:error, settlement_error}, {:error, neutral_error}} ->
        {:accounting_failure, :merge_compaction_projection_cleanup,
         {settlement_error, neutral_error}}
    end
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
