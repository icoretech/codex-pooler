defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV4 do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest

  @base_fields [
    :url,
    :headers,
    :payload,
    :timeouts,
    :mapper,
    :upstream_identity_id,
    :observation,
    :reset_probe,
    :native_codex_response_control,
    :assignment_advertised?,
    :connection_bound_continuation?,
    :forward_error_body?,
    :submission_notification?
  ]
  @fields [:version | @base_fields] ++
            [
              :websocket_delivery_mode,
              :effective_serving_mode,
              :native_replay_binding,
              :native_replay_proof,
              :provisional_token
            ]
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{}
  @type validation_error :: WebsocketOwnerRequest.validation_error()

  @spec new(map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_keys(attrs),
         request = struct!(__MODULE__, attrs),
         :ok <- validate(request) do
      {:ok, request}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :envelope}}

  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = request) do
    with true <- request.version == 4,
         true <- request.websocket_delivery_mode in [:relay, :collect_compaction],
         true <- request.effective_serving_mode in [:full, :lite],
         %Binding{} <- request.native_replay_binding,
         %RuntimeAdmissionProof{kind: :native_replay} <-
           request.native_replay_proof,
         {:ok, _digest} <-
           NativeReplayAdmission.binding_digest(request.native_replay_binding),
         true <-
           is_binary(request.provisional_token) and byte_size(request.provisional_token) == 32,
         {:ok, v1} <- WebsocketOwnerRequest.new(v1_attrs(request)) do
      WebsocketOwnerRequest.validate(v1)
    else
      false -> {:error, {:invalid_field, invalid_field(request)}}
      nil -> {:error, {:invalid_field, :native_replay_binding}}
      {:error, :invalid_binding} -> {:error, {:invalid_field, :native_replay_binding}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_request), do: {:error, {:invalid_field, :envelope}}

  defp invalid_field(%{version: version}) when version != 4, do: :version

  defp invalid_field(%{websocket_delivery_mode: mode})
       when mode not in [:relay, :collect_compaction], do: :websocket_delivery_mode

  defp invalid_field(%{effective_serving_mode: mode}) when mode not in [:full, :lite],
    do: :effective_serving_mode

  defp invalid_field(%{native_replay_proof: proof})
       when not is_struct(
              proof,
              CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
            ),
       do: :native_replay_proof

  defp invalid_field(_request), do: :provisional_token

  defp v1_attrs(request),
    do: request |> Map.from_struct() |> Map.take(@base_fields) |> Map.put(:version, 1)

  defp exact_keys(attrs) do
    unknown = Map.keys(attrs) -- @fields
    missing = @fields -- Map.keys(attrs)

    cond do
      unknown != [] -> {:error, {:unknown_fields, Enum.sort_by(unknown, &to_string/1)}}
      missing != [] -> {:error, {:invalid_field, hd(missing)}}
      true -> :ok
    end
  end
end

defimpl Inspect, for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV4 do
  def inspect(_request, _opts), do: "#WebsocketOwnerRequestV4<version: 4, replay: redacted>"
end
