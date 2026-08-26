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
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @secret_kind "access_token"
  @type dispatch_candidate :: (PreparedContext.t() -> dispatch_candidate_result())
  @type dispatch_candidate_result :: Dispatch.dispatch_result()
  @type dispatch_result :: {:ok, GatewayContracts.gateway_result()} | {:error, map()}

  defmodule Operations do
    @moduledoc false

    alias CodexPooler.Accounting
    alias CodexPooler.Accounting.FailureResponse
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
    @type finalize_failure :: (Accounting.Request.t(), Accounting.Attempt.t(), map() -> term())
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
        finalize_failure: &AttemptSettlement.finalize_failure/3,
        neutral_completion: &DispatchLifecycle.neutral_completion/1,
        accounting_failure: &FailureResponse.accounting_failure/4
      }
    end

    @spec build(t() | map()) :: t()
    def build(%__MODULE__{} = operations), do: operations
    def build(overrides) when is_map(overrides), do: struct!(defaults(), overrides)
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
           ) do
      request_options = context.request_options

      {upstream_payload, request_options} =
        RequestCompression.maybe_compress(upstream_payload, context, request_options)

      context = %{context | request_options: request_options}

      dispatch_fun.(%PreparedContext{
        context: context,
        token: token,
        url: url,
        upstream_payload: upstream_payload,
        routing_hint_authorized?: UpstreamIdentity.authenticated_codex_chatgpt?(context.identity)
      })
    else
      {:compaction_projection_merge_error, reason} ->
        handle_compaction_projection_merge_failure(context, reason, operations)

      {:error, reason} ->
        Finalization.handle_dispatch_error(reason, context, elapsed_ms(context.started))
    end
  end

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
            )
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
