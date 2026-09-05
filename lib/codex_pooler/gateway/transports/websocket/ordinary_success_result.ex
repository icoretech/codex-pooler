defmodule CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.FirstCompactResult
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct

  @enforce_keys [
    :owner,
    :result_ref,
    :request_id,
    :attempt_id,
    :response_digest,
    :model_digest,
    :serving_mode,
    :lifecycle,
    :topology
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          owner: pid(),
          result_ref: reference(),
          request_id: Ecto.UUID.t(),
          attempt_id: Ecto.UUID.t(),
          response_digest: <<_::256>>,
          model_digest: <<_::256>>,
          serving_mode: :full | :lite,
          lifecycle: map(),
          topology: struct()
        }

  @spec from_response(map(), term(), map()) :: {:ok, t()} | :error
  def from_response(request, {:ok, %{response_id: id, terminal: terminal}}, lifecycle)
      when is_binary(id) and terminal in ["response.completed", "response.done"] do
    with :relay <- request.websocket_delivery_mode,
         {:ok, request_id} <- Ecto.UUID.cast(request.request_id),
         {:ok, attempt_id} <- Ecto.UUID.cast(request.attempt_id),
         {:ok, %{"model" => model}} when is_binary(model) <- Jason.decode(request.payload),
         mode when mode in ["full", "lite"] <- request.effective_serving_mode do
      {:ok,
       %__MODULE__{
         owner: self(),
         result_ref: make_ref(),
         request_id: request_id,
         attempt_id: attempt_id,
         response_digest: NativeCodexTurnMetadata.response_id_digest(id),
         model_digest: FirstCompactResult.model_digest(model),
         serving_mode: if(mode == "full", do: :full, else: :lite),
         lifecycle: lifecycle,
         topology: %Direct{}
       }}
    else
      _invalid -> :error
    end
  end

  def from_response(_request, _result, _lifecycle), do: :error

  @spec binding_matches?(t(), Binding.t()) :: boolean()
  def binding_matches?(%__MODULE__{} = receipt, %Binding{} = binding) do
    receipt.response_digest == binding.previous_response_digest and
      receipt.serving_mode == binding.serving_mode and receipt.topology == binding.topology and
      receipt.lifecycle == Map.take(binding, [:lifecycle_id, :generation])
  end
end

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult do
  def inspect(_result, _opts), do: "#OrdinarySuccessResult<redacted>"
end
