defmodule CodexPooler.Gateway.Runtime.Dispatch.PreparedNativePayloads do
  @moduledoc false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.{PayloadNormalizer, RequestOptions}
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer.PreparedJSON
  alias CodexPooler.Gateway.Routing.{BridgeRing, ModelMetadata}
  alias CodexPooler.Gateway.Runtime.Dispatch

  @derive {Inspect, only: []}
  @enforce_keys [:assignment_variants, :variants, :binding]
  defstruct @enforce_keys

  @type signature :: {boolean(), boolean(), [String.t()]}
  @type binding :: %{
          endpoint: String.t(),
          upstream_model: String.t(),
          payload: map(),
          options: map()
        }
  @type t :: %__MODULE__{
          assignment_variants: %{Ecto.UUID.t() => signature()},
          variants: %{signature() => PreparedJSON.t()},
          binding: binding()
        }
  @type preparation_error :: CodexPooler.JSON.encode_error() | CodexPooler.Gateway.OpenAICompatibility.Error.reason()

  # The caller supplies every reachable cohort (eligible, held-back and deferred).
  # This never selects, filters or reorders a route. Immutable input is retained
  # once for binding, while equivalent candidates share one encoded binary.
  @spec prepare(map(), Model.t(), String.t(), RequestOptions.t(), [BridgeRing.candidate()], non_neg_integer()) ::
          {:ok, t()} | {:oversized, non_neg_integer()} | {:error, preparation_error()}
  def prepare(payload, model, endpoint, request_options, candidates, limit_bytes) do
    initial = %__MODULE__{assignment_variants: %{}, variants: %{}, binding: binding(payload, model, endpoint, request_options)}

    Enum.reduce_while(candidates, {:ok, initial}, fn {assignment, _identity}, {:ok, prepared} ->
      options = RequestOptions.put_routing(request_options, Dispatch.payload_selection_updates(model, assignment.id, request_options))
      signature = signature(model, assignment.id, options)

      case prepare_variant(prepared, signature, payload, model, endpoint, options, assignment.id) do
        {:ok, variant} when byte_size(variant.encoded) <= limit_bytes ->
          {:cont, {:ok, %{prepared | assignment_variants: Map.put(prepared.assignment_variants, assignment.id, signature), variants: Map.put(prepared.variants, signature, variant)}}}

        {:ok, variant} ->
          {:halt, {:oversized, byte_size(variant.encoded)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @spec fetch(t(), map(), Model.t(), String.t(), RequestOptions.t(), Ecto.UUID.t()) ::
          {:ok, binary(), RequestOptions.t()} | {:error, :prepared_native_payload_binding_mismatch}
  def fetch(%__MODULE__{} = prepared, payload, model, endpoint, request_options, assignment_id) do
    with true <- prepared.binding == binding(payload, model, endpoint, request_options),
         {:ok, signature} <- Map.fetch(prepared.assignment_variants, assignment_id),
         true <- signature == signature(model, assignment_id, request_options),
         {:ok, variant} <- Map.fetch(prepared.variants, signature) do
      {:ok, variant.encoded, PayloadNormalizer.apply_prepared_json(variant, payload, model, endpoint, request_options)}
    else
      _mismatch -> {:error, :prepared_native_payload_binding_mismatch}
    end
  end

  defp prepare_variant(prepared, signature, payload, model, endpoint, options, assignment_id) do
    case Map.fetch(prepared.variants, signature) do
      {:ok, variant} -> {:ok, variant}
      :error -> PayloadNormalizer.prepare_json_payload(payload, model, endpoint, options, assignment_id: assignment_id)
    end
  end

  defp signature(model, assignment_id, options) do
    {RequestOptions.use_responses_lite?(options), options.routing.supports_reasoning_summary_parameter?, Enum.sort(ModelMetadata.selected_reasoning_levels(model, assignment_id))}
  end

  # Complete normalization read-set, apart from the candidate signature above.
  # Owner, epoch, auth, route, circuit and retry state intentionally remain live.
  defp binding(payload, model, endpoint, options) do
    %{
      endpoint: endpoint,
      upstream_model: model.upstream_model_id,
      payload: payload,
      options: %{
        transport: Map.take(options.transport, [:transport, :upstream_endpoint]),
        serving_snapshot: RequestOptions.model_serving_mode_snapshot(options),
        effective_model: options.routing.effective_model,
        policy: Map.take(options.routing.api_key_policy || %{}, [:enforced_reasoning_effort, :enforced_service_tier]),
        reasoning_decision: options.routing.reasoning_effort_decision,
        compatibility: Map.take(options.openai_compatibility, [:source_endpoint, :translated_endpoint, :public_openai_responses_stream]),
        payload_context: Map.take(options.payload_context, [:native_image_request?, :compaction_trigger_bridge?, :compaction_result_transport, :compaction_input_mode, :compaction_projection_context]),
        previous_response_serving_mode: options.continuity.previous_response_serving_mode,
        input_index_unknown?: options.runtime.upstream_input_index_map == :unknown
      }
    }
  end
end
